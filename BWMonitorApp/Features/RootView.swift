import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage("appearance") private var appearance = "system"
    @State private var showingAddServer = false

    var body: some View {
        NavigationSplitView {
            List(selection: $state.selection) {
                Section {
                    sidebarItem(.overview)
                }

                Section("Monitoring") {
                    sidebarItem(.performance)
                    sidebarItem(.network)
                    sidebarItem(.traffic)
                }

                Section("Management") {
                    sidebarItem(.terminal)
                    sidebarItem(.services)
                    sidebarItem(.processes)
                }

                Section {
                    sidebarItem(.servers)
                    sidebarItem(.settings)
                }
            }
            .navigationTitle("BWMonitor")
            .safeAreaInset(edge: .bottom) {
                serverPicker
                    .padding(10)
                    .background(.bar)
            }
        } detail: {
            detail
                .toolbar { toolbar }
                .overlay(alignment: .bottom) {
                    if let error = state.lastError {
                        ErrorBanner(message: error) { state.lastError = nil }
                            .padding()
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
        }
        .sheet(isPresented: $showingAddServer) {
            ServerEditorView(server: nil)
                .environmentObject(state)
        }
        .preferredColorScheme(colorScheme)
    }

    private func sidebarItem(_ destination: SidebarDestination) -> some View {
        Label(destination.localizedTitle, systemImage: destination.symbol)
            .tag(destination)
    }

    @ViewBuilder
    private var detail: some View {
        if state.servers.isEmpty, state.selection != .servers, state.selection != .settings {
            EmptySelectionView(
                title: LocalizedStringKey("Add your first VPS"),
                message: LocalizedStringKey("Server credentials stay in your Mac Keychain."),
                action: { showingAddServer = true }
            )
        } else {
            switch state.selection {
            case .overview:
                DashboardView()
            case .performance:
                PerformanceView()
            case .network:
                NetworkView()
            case .traffic:
                TrafficView()
            case .terminal:
                TerminalView()
            case .services:
                ServicesView()
            case .processes:
                ProcessesView()
            case .servers:
                ServersView(showingAddServer: $showingAddServer)
            case .settings:
                SettingsView()
            }
        }
    }

    private var serverPicker: some View {
        Picker("Server", selection: $state.selectedServerID) {
            Text("No Server").tag(UUID?.none)
            ForEach(state.servers) { server in
                Text(server.name).tag(Optional(server.id))
            }
        }
        .labelsHidden()
        .onChange(of: state.selectedServerID) { _, newValue in
            state.stopMonitoring()
            if let newValue { state.loadHistory(for: newValue) }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if state.monitoringActive {
                Button("Stop Monitoring", systemImage: "pause.fill") {
                    state.stopMonitoring()
                }
            } else {
                Button("Start Monitoring", systemImage: "play.fill") {
                    state.beginMonitoring()
                }
                .disabled(state.selectedServer == nil || state.isDemoMode)
            }

            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await state.refreshAll() }
            }
            .disabled(state.selectedServer == nil || state.isRefreshing || state.isDemoMode)

            if state.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}
