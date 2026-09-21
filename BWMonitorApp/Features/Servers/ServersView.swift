import SwiftUI

struct ServersView: View {
    @EnvironmentObject private var state: AppState
    @State private var deletingServer: Server?

    var body: some View {
        VStack(spacing: 0) {
            if state.servers.isEmpty {
                EmptySelectionView(
                    title: LocalizedStringKey("No servers"),
                    message: LocalizedStringKey("Add a VPS to begin monitoring."),
                    action: { state.addServer() }
                )
            } else {
                List(state.servers, selection: $state.selectedServerID) { server in
                    ServerRow(
                        server: server,
                        connection: state.connectionByServer[server.id] ?? .idle,
                        trusted: state.ssh.isTrusted(server)
                    )
                    .tag(server.id)
                    .contextMenu {
                        Button("Edit…") { state.edit(server) }
                        Button("Open in Terminal") { state.openInExternalTerminal(server) }
                            .disabled(!state.ssh.isTrusted(server) || state.isDemoMode)
                        Divider()
                        Button("Delete…", role: .destructive) { deletingServer = server }
                    }
                }
            }
        }
        .navigationTitle("Servers")
        .toolbar {
            ToolbarItemGroup {
                Button("Add Server", systemImage: "plus") { state.addServer() }
                Button("Edit Server", systemImage: "pencil") {
                    if let server = state.selectedServer { state.edit(server) }
                }
                .disabled(state.selectedServer == nil)
            }
        }
        .alert("Delete Server?", isPresented: Binding(
            get: { deletingServer != nil },
            set: { if !$0 { deletingServer = nil } }
        ), presenting: deletingServer) { server in
            Button("Delete", role: .destructive) { Task { await state.deleteServer(server) } }
            Button("Cancel", role: .cancel) {}
        } message: { server in
            Text(
                String(
                    format: NSLocalizedString(
                        "%@ and its Keychain credentials will be removed from BWMonitor. The VPS itself is not changed.",
                        comment: "Server deletion confirmation"
                    ),
                    server.name
                )
            )
        }
    }
}

private struct ServerRow: View {
    let server: Server
    let connection: ConnectionState
    let trusted: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundStyle(connection.isConnected ? Color.accentColor : Color.secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.headline)
                Text(verbatim: "\(server.username)@\(server.host):\(server.port)")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                ConnectionBadge(connection: connection, trusted: trusted)
                Text(server.operatingSystem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

/// A short, colored description of a server's SSH state.
struct ConnectionBadge: View {
    let connection: ConnectionState
    let trusted: Bool

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }

    private var title: LocalizedStringKey {
        if !trusted { return "Not set up" }
        switch connection {
        case .idle: return "Not monitoring"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .retrying: return "Reconnecting"
        case .needsAttention: return "Needs attention"
        case .failed: return "Error"
        }
    }

    private var symbol: String {
        if !trusted { return "questionmark.circle" }
        switch connection {
        case .idle: return "pause.circle"
        case .connecting: return "ellipsis.circle"
        case .connected: return "checkmark.circle.fill"
        case .retrying: return "arrow.clockwise.circle"
        case .needsAttention, .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        if !trusted { return .secondary }
        switch connection {
        case .connected: return .green
        case .retrying: return .orange
        case .needsAttention, .failed: return .red
        case .idle, .connecting: return .secondary
        }
    }
}
