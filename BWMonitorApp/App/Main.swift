import Foundation

/// Entry point. When OpenSSH starts BWMonitor as its askpass helper, answer
/// and exit before any UI is created; otherwise run the app.
@main
enum BWMonitorMain {
    @MainActor
    static func main() {
        if let status = SSHAskpass.runIfRequested() {
            exit(status)
        }
        if CommandLine.arguments.contains("--debug-self-update") {
            SoftwareUpdater.runDebugSelfUpdate()
        }
        BWMonitorApp.main()
    }
}
