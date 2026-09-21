import SwiftUI

@main
struct BWMonitorApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("BWMonitor", id: "dashboard") {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 980, minHeight: 680)
                .task { await state.checkForUpdates() }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Refresh") { Task { await state.refreshAll() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
        } label: {
            Label(menuBarTitle, systemImage: "server.rack")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(state)
                .frame(width: 620, height: 500)
        }
    }

    private var menuBarTitle: String {
        if let metrics = state.selectedMetrics {
            return "\(Int(metrics.cpuUsage * 100))% · \(Int(metrics.memoryPercentage * 100))%"
        }
        return "BWMonitor"
    }
}
