import SwiftUI

struct TerminalView: View {
    @EnvironmentObject private var state: AppState

    private var selectedSession: TerminalSession? {
        state.terminalSessions.first { $0.id == state.selectedTerminalID }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if let session = selectedSession {
                TerminalPane(session: session)
            } else {
                ContentUnavailableView {
                    Label("No terminal session", systemImage: "terminal")
                } description: {
                    Text("Choose a server and open a shell. Saved passwords and passphrases are used automatically.")
                } actions: {
                    Menu("New Terminal", systemImage: "plus") {
                        terminalServerChoices
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canOpenAny)
                }
            }
        }
        .navigationTitle("Terminal")
    }

    private var canOpenAny: Bool {
        !state.isDemoMode && state.servers.contains(where: state.ssh.isTrusted)
    }

    private var externalServer: Server? {
        selectedSession?.server ?? state.selectedServer
    }

    @ViewBuilder
    private var terminalServerChoices: some View {
        ForEach(state.servers) { server in
            Button {
                state.openTerminal(for: server)
            } label: {
                Label(server.name, systemImage: state.connectionByServer[server.id]?.isConnected == true
                    ? "checkmark.circle.fill"
                    : "server.rack")
            }
            .disabled(!state.ssh.isTrusted(server))
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(state.terminalSessions) { session in
                        TerminalTab(
                            session: session,
                            selected: session.id == state.selectedTerminalID,
                            select: { state.selectedTerminalID = session.id },
                            close: { state.closeTerminal(session) }
                        )
                    }
                }
            }
            .scrollIndicators(.never)
            Spacer()
            Button("Open in Terminal", systemImage: "arrow.up.forward.app") {
                if let externalServer { state.openInExternalTerminal(externalServer) }
            }
            .labelStyle(.iconOnly)
            .disabled(externalServer.map(state.ssh.isTrusted) != true)
            .help("Open in Terminal")
            Menu {
                terminalServerChoices
            } label: {
                Label("New Terminal", systemImage: "plus")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!canOpenAny)
            .help("New Terminal")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.bar)
    }
}

private struct TerminalTab: View {
    @ObservedObject var session: TerminalSession
    let selected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 7) {
                Circle()
                    .fill(session.isConnected ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(session.server.name)
                    .lineLimit(1)
                    .frame(maxWidth: 180)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(
                    format: NSLocalizedString("Close %@ terminal", comment: "Accessibility label"),
                    session.title
                )))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

private struct TerminalPane: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            if session.isRunningFullScreenProgram {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.on.rectangle")
                        .foregroundStyle(.orange)
                    Text("A full-screen program (such as vim, top or less) is running. It needs a full terminal: quit it with q or Control-C, or open the server in Terminal.")
                        .font(.callout)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Open in Terminal") { state.openInExternalTerminal(session.server) }
                        .fixedSize()
                }
                .padding(10)
                .background(.orange.opacity(0.1))
                Divider()
            }
            TerminalOutput(session: session)
            if !session.isConnected {
                Divider()
                HStack {
                    Text("Disconnected")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reconnect") {
                        let server = state.servers.first { $0.id == session.server.id } ?? session.server
                        state.closeTerminal(session)
                        state.openTerminal(for: server)
                    }
                }
                .padding(10)
            }
        }
    }
}
