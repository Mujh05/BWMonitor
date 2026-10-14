import Foundation
import Testing

@testable import BWMonitorCore

@Suite("Operation cancellation")
struct OperationCancellationTests {
    @Test("Cancelled Swift and URL operations are silent")
    func cancellations() {
        #expect(OperationCancellation.isCancellation(CancellationError()))
        #expect(OperationCancellation.isCancellation(URLError(.cancelled)))
        #expect(OperationCancellation.isCancellation(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
    }

    @Test("Timeouts and connection errors remain visible")
    func realFailures() {
        #expect(!OperationCancellation.isCancellation(URLError(.timedOut)))
        #expect(!OperationCancellation.isCancellation(URLError(.cannotConnectToHost)))
        #expect(!OperationCancellation.isCancellation(SSHError.authenticationFailed(methods: "publickey")))
        #expect(!OperationCancellation.isCancellation(NSError(domain: "OtherError", code: NSURLErrorCancelled)))
    }

    @Test("Cancelling an in-flight SSH subprocess is classified as cancellation")
    func cancelledSubprocess() async throws {
        let operation = Task {
            try await ProcessRunner.run("/bin/sleep", arguments: ["10"], timeout: 15)
        }
        try await Task.sleep(for: .milliseconds(50))
        operation.cancel()
        do {
            _ = try await operation.value
            Issue.record("The cancelled subprocess returned a result")
        } catch {
            #expect(OperationCancellation.isCancellation(error))
        }
    }
}
