import Darwin
import Foundation

public struct ProcessOutput: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
}

public enum ProcessRunnerError: LocalizedError, Equatable {
    case timedOut
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut:
            NSLocalizedString("SSH operation timed out.", comment: "SSH timeout error")
        case let .launchFailed(message):
            message
        }
    }
}

/// Runs a command-line tool and collects its output.
///
/// Both pipes are drained while the tool runs, so large output cannot fill a
/// pipe and stall the child. A timeout or task cancellation terminates it.
enum ProcessRunner {
    static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        input: Data? = nil,
        timeout: TimeInterval
    ) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = input.map { _ in Pipe() }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe ?? FileHandle.nullDevice

        let run = RunState(process: process)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutput, Error>) in
                // Cancellation can arrive before the continuation exists.
                guard run.setCallback({ continuation.resume(with: $0) }) else { return }

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        run.streamClosed()
                    } else {
                        run.append(stdout: data)
                    }
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        run.streamClosed()
                    } else {
                        run.append(stderr: data)
                    }
                }
                process.terminationHandler = { _ in
                    run.exited()
                    // A grandchild can keep a pipe open after the tool exits
                    // (for example a backgrounded SSH master). Stop waiting
                    // for end-of-file shortly after exit.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { run.complete() }
                }

                do {
                    try process.run()
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    run.fail(ProcessRunnerError.launchFailed(error.localizedDescription))
                    return
                }

                if let input, let stdinPipe {
                    let handle = stdinPipe.fileHandleForWriting
                    // Report EPIPE instead of raising SIGPIPE if the tool
                    // exits before reading everything.
                    _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
                    DispatchQueue.global().async {
                        try? handle.write(contentsOf: input)
                        try? handle.close()
                    }
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    run.fail(ProcessRunnerError.timedOut)
                }
            }
        } onCancel: {
            run.fail(CancellationError())
        }
    }
}

private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var stdout = Data()
    private var stderr = Data()
    private var pendingEvents = 3 // stdout EOF, stderr EOF, exit
    private var hasExited = false
    private var finished = false
    private var onFinish: ((Result<ProcessOutput, Error>) -> Void)?
    private var earlyResult: Result<ProcessOutput, Error>?

    init(process: Process) {
        self.process = process
    }

    /// Installs the result callback. Returns false (after delivering the
    /// result) when the run already failed, so the tool must not be started.
    func setCallback(_ callback: @escaping (Result<ProcessOutput, Error>) -> Void) -> Bool {
        lock.lock()
        if let earlyResult {
            lock.unlock()
            callback(earlyResult)
            return false
        }
        onFinish = callback
        lock.unlock()
        return true
    }

    func append(stdout data: Data) { lock.withLock { stdout.append(data) } }
    func append(stderr data: Data) { lock.withLock { stderr.append(data) } }

    func streamClosed() { countEvent() }

    func exited() {
        lock.withLock { hasExited = true }
        countEvent()
    }

    private func countEvent() {
        let done = lock.withLock {
            pendingEvents -= 1
            return pendingEvents == 0
        }
        if done { complete() }
    }

    /// Delivers the collected output once the tool has exited.
    func complete() {
        lock.lock()
        guard !finished, hasExited else {
            lock.unlock()
            return
        }
        finished = true
        let output = ProcessOutput(
            status: process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
        deliver(.success(output))
    }

    /// Stops the tool and reports `error`, unless a result was already delivered.
    func fail(_ error: Error) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        deliver(.failure(error))
        terminate()
    }

    /// Called with the lock held; releases it.
    private func deliver(_ result: Result<ProcessOutput, Error>) {
        guard let callback = onFinish else {
            earlyResult = result
            lock.unlock()
            return
        }
        onFinish = nil
        lock.unlock()
        callback(result)
    }

    private func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
