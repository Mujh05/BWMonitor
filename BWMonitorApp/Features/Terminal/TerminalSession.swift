import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    let server: Server
    @Published var output = ""
    @Published var isConnected = false
    @Published var title: String
    @Published var command = ""
    @Published var history: [String] = []

    private var process: Process?
    private var masterHandle: FileHandle?
    private var slaveHandle: FileHandle?
    private var sentPassword = false
    private var sentPassphrase = false
    private let ssh: SSHManager
    private let keychain: KeychainStore

    init(server: Server, ssh: SSHManager, keychain: KeychainStore) {
        self.server = server
        self.ssh = ssh
        self.keychain = keychain
        title = server.name
    }

    func connect() async {
        guard process == nil else { return }
        do {
            switch try await ssh.hostKeyStatus(for: server) {
            case .trusted:
                break
            case .unknown:
                throw SSHError.hostNotTrusted
            case .changed:
                throw SSHError.hostKeyChanged
            }
            let password = try keychain.read(for: server.id, kind: .sshPassword)
            let passphrase = try keychain.read(for: server.id, kind: .privateKeyPassphrase)
            try launch(password: password, passphrase: passphrase)
        } catch {
            append(
                "\r\n[\(NSLocalizedString("Connection blocked", comment: "Terminal connection status"))] "
                    + "\(error.localizedDescription)\r\n"
            )
        }
    }

    func sendCurrentCommand() {
        guard !command.isEmpty else { return }
        history.append(command)
        send(command + "\n")
        command = ""
    }

    func send(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        do {
            try masterHandle?.write(contentsOf: data)
        } catch {
            append(
                "\r\n[\(NSLocalizedString("Write failed", comment: "Terminal write error"))] "
                    + "\(error.localizedDescription)\r\n"
            )
        }
    }

    func resize(rows: UInt16, columns: UInt16) {
        guard let masterHandle else { return }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterHandle.fileDescriptor, TIOCSWINSZ, &size)
    }

    func disconnect() {
        masterHandle?.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
        try? masterHandle?.close()
        try? slaveHandle?.close()
        masterHandle = nil
        slaveHandle = nil
        process = nil
        isConnected = false
    }

    private func launch(password: String?, passphrase: String?) throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw SSHError.commandFailed(
                NSLocalizedString("Could not create a pseudo terminal.", comment: "Terminal setup error")
            )
        }
        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        self.masterHandle = masterHandle
        self.slaveHandle = slaveHandle

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var arguments = ssh.connectionArguments(for: server, batchMode: false)
        arguments += ["-tt", "\(server.username)@\(server.host)"]
        process.arguments = arguments
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.append(
                    "\r\n[" + String(
                        format: NSLocalizedString("Session ended: %d", comment: "Terminal exit status"),
                        process.terminationStatus
                    ) + "]\r\n"
                )
                self?.isConnected = false
            }
        }
        masterHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.receive(text, password: password, passphrase: passphrase)
            }
        }
        try process.run()
        self.process = process
        isConnected = true
        append(
            String(
                format: NSLocalizedString("Connecting securely to %@…", comment: "Terminal connection status"),
                server.name
            ) + "\r\n"
        )
    }

    private func receive(_ text: String, password: String?, passphrase: String?) {
        let lower = text.lowercased()
        if lower.contains("password:"), let password, !sentPassword {
            sentPassword = true
            send(password + "\n")
        } else if lower.contains("enter passphrase for key"), let passphrase, !sentPassphrase {
            sentPassphrase = true
            send(passphrase + "\n")
        }
        append(text)
    }

    private func append(_ text: String) {
        output += text
        if output.count > 160_000 {
            output.removeFirst(output.count - 120_000)
        }
    }
}

enum ANSIParser {
    static func attributed(_ source: String) -> AttributedString {
        var result = AttributedString()
        var foreground: Color = .primary
        let pattern = #"\u{001B}\[([0-9;]*)m"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return AttributedString(source)
        }
        let ns = source as NSString
        var location = 0
        for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > location {
                var segment = AttributedString(ns.substring(with: NSRange(location: location, length: match.range.location - location)))
                segment.foregroundColor = foreground
                result.append(segment)
            }
            let codes = match.range(at: 1).location == NSNotFound
                ? []
                : ns.substring(with: match.range(at: 1)).split(separator: ";").compactMap { Int($0) }
            for code in codes.isEmpty ? [0] : codes {
                foreground = color(for: code) ?? (code == 0 ? .primary : foreground)
            }
            location = match.range.location + match.range.length
        }
        if location < ns.length {
            var segment = AttributedString(ns.substring(from: location))
            segment.foregroundColor = foreground
            result.append(segment)
        }
        return result
    }

    private static func color(for code: Int) -> Color? {
        switch code {
        case 30: .black
        case 31, 91: .red
        case 32, 92: .green
        case 33, 93: .yellow
        case 34, 94: .blue
        case 35, 95: .purple
        case 36, 96: .cyan
        case 37, 97: .white
        default: nil
        }
    }
}
