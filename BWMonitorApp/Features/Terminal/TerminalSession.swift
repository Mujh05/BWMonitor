import AppKit
import Combine
import Darwin
import Foundation

/// One interactive SSH shell in BWMonitor's terminal.
///
/// ssh runs in its own session with a pseudo-terminal as its controlling
/// terminal, like in Terminal.app: it can prompt for a password when none is
/// saved, and window size changes reach the server. Saved secrets are
/// supplied by the askpass helper, never typed into the session.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    let server: Server
    let buffer = TerminalBuffer()
    @Published private(set) var title: String
    @Published private(set) var isConnected = false
    @Published private(set) var isRunningFullScreenProgram = false

    /// Receives every change to `buffer`, for drawing.
    var onUpdate: ((TerminalUpdate) -> Void)?

    private let ssh: SSHManager
    private var pid: pid_t = 0
    private var master: FileHandle?
    private var exitSource: DispatchSourceProcess?
    private var size = winsize(ws_row: 30, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)

    init(server: Server, ssh: SSHManager) {
        self.server = server
        self.ssh = ssh
        title = server.name
        buffer.resize(columns: Int(size.ws_col), rows: Int(size.ws_row))
    }

    func connect() {
        guard pid == 0 else { return }
        do {
            let invocation = try ssh.terminalInvocation(for: server)
            notice(String(
                format: NSLocalizedString("Connecting securely to %@…", comment: "Terminal connection status"),
                server.name
            ))
            try launch(invocation)
        } catch {
            notice(
                NSLocalizedString("Connection blocked", comment: "Terminal connection status")
                    + ": " + error.localizedDescription
            )
        }
    }

    func send(_ data: Data) {
        guard let master else { return }
        do {
            try master.write(contentsOf: data)
        } catch {
            notice(NSLocalizedString("Write failed", comment: "Terminal write error") + ": " + error.localizedDescription)
        }
    }

    func send(_ text: String) {
        send(Data(text.utf8))
    }

    /// Pastes text as the shell expects: line breaks become returns, and
    /// with bracketed paste the shell does not run pasted lines by itself.
    func paste(_ text: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        send(buffer.bracketedPaste ? "\u{1B}[200~" + normalized + "\u{1B}[201~" : normalized)
    }

    func resize(columns: Int, rows: Int) {
        let columns = UInt16(clamping: max(columns, 20))
        let rows = UInt16(clamping: max(rows, 5))
        guard columns != size.ws_col || rows != size.ws_row else { return }
        size.ws_col = columns
        size.ws_row = rows
        buffer.resize(columns: Int(columns), rows: Int(rows))
        if let master { _ = ioctl(master.fileDescriptor, TIOCSWINSZ, &size) }
    }

    func clearScrollback() {
        buffer.clear()
        onUpdate?(TerminalUpdate(removedLines: 0, firstChangedLine: 0))
    }

    func disconnect() {
        master?.readabilityHandler = nil
        if pid > 0, isConnected { kill(pid, SIGHUP) }
        try? master?.close()
        master = nil
        isConnected = false
    }

    // MARK: Process

    private func launch(_ invocation: SSHManager.Invocation) throws {
        var environment = ProcessInfo.processInfo.environment.merging(invocation.environment) { $1 }
        environment["TERM"] = "xterm-256color"
        environment["LANG"] = environment["LANG"] ?? "C.UTF-8"

        // Everything the child needs is allocated before forking: between
        // fork and exec only async-signal-safe calls are allowed.
        let path = strdup("/usr/bin/ssh")
        let arguments = CStringArray(["/usr/bin/ssh"] + invocation.arguments)
        let environmentList = CStringArray(environment.map { "\($0.key)=\($0.value)" })
        defer {
            free(path)
            arguments.deallocate()
            environmentList.deallocate()
        }
        // forkpty makes the pseudo-terminal ssh's controlling terminal, with
        // ssh in the foreground, so ssh can ask for a password or passphrase.
        var masterFD: Int32 = -1
        let childPID = forkpty(&masterFD, nil, nil, &size)
        if childPID == 0 {
            execve(path, arguments.pointer, environmentList.pointer)
            _exit(127)
        }
        guard childPID > 0 else {
            throw SSHError.commandFailed(
                NSLocalizedString("Could not create a pseudo terminal.", comment: "Terminal setup error")
            )
        }
        let masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)

        pid = childPID
        master = masterHandle
        isConnected = true

        masterHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            // The main queue keeps chunks in order.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(data) } }
        }

        let source = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            var exitStatus: Int32 = 0
            waitpid(childPID, &exitStatus, 0)
            MainActor.assumeIsolated { self?.processExited(status: exitStatus) }
        }
        source.resume()
        exitSource = source
    }

    private func receive(_ data: Data) {
        let update = buffer.feed(data)
        if let title = buffer.title, !title.isEmpty, title != self.title { self.title = title }
        if buffer.alternateScreen != isRunningFullScreenProgram {
            isRunningFullScreenProgram = buffer.alternateScreen
        }
        onUpdate?(update)
    }

    private func processExited(status: Int32) {
        exitSource?.cancel()
        exitSource = nil
        isConnected = false
        isRunningFullScreenProgram = false
        let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
        // Let the last output arrive before closing the terminal.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.master?.readabilityHandler = nil
                try? self.master?.close()
                self.master = nil
                self.notice(String(format: NSLocalizedString("Session ended: %d", comment: "Terminal exit status"), code))
            }
        }
    }

    private func notice(_ text: String) {
        let prefix = buffer.lines.last?.isEmpty == false ? "\r\n" : ""
        onUpdate?(buffer.feed(prefix + "\u{1B}[2m" + text + "\u{1B}[0m\r\n"))
    }
}

/// A NULL-terminated array of C strings for execve.
private struct CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointer = .allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() { pointer[index] = strdup(string) }
        pointer[strings.count] = nil
    }

    func deallocate() {
        for index in 0..<count { free(pointer[index]) }
        pointer.deallocate()
    }
}
