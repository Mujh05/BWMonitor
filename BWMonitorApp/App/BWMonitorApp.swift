import SwiftUI

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
            if let title = menuBarTitle {
                HStack(spacing: 4) {
                    Image(systemName: "server.rack")
                    Text(title)
                }
            } else {
                Image(systemName: "server.rack")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(state)
                .frame(width: 620, height: 500)
        }
    }

    /// CPU and memory while live data arrives; just the icon otherwise, so
    /// stale numbers never sit in the menu bar.
    private var menuBarTitle: String? {
        guard state.selectedConnection.isConnected, let metrics = state.selectedMetrics else { return nil }
        return "\(Int(metrics.cpuUsage * 100))% · \(Int(metrics.memoryPercentage * 100))%"
    }
}
