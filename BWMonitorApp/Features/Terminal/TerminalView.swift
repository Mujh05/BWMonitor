import SwiftUI

struct TerminalView: View {
    @EnvironmentObject private var state: AppState
    @State private var sessions: [TerminalSession] = []
    @State private var selectedSessionID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if let session = sessions.first(where: { $0.id == selectedSessionID }) {
                TerminalPane(session: session)
            } else {
                ContentUnavailableView {
                    Label("No terminal session", systemImage: "terminal")
                } description: {
                    Text("Verify the SSH host key before opening a terminal.")
                } actions: {
                    Button("New Terminal") { addSession() }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.selectedServer == nil || state.isDemoMode)
                }
            }
        }
        .navigationTitle("Terminal")
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(sessions) { session in
                        Button {
                            selectedSessionID = session.id
                        } label: {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(session.isConnected ? Color.green : Color.secondary)
                                    .frame(width: 7, height: 7)
                                Text(session.title)
                                Button {
                                    close(session)
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Close \(session.title) terminal")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(selectedSessionID == session.id ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer()
            Button("New Terminal", systemImage: "plus") { addSession() }
                .labelStyle(.iconOnly)
                .disabled(state.selectedServer == nil || state.isDemoMode)
                .help("New Terminal")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.bar)
    }

    private func addSession() {
        guard let server = state.selectedServer else { return }
        let session = TerminalSession(server: server, ssh: state.ssh, keychain: state.keychain)
        sessions.append(session)
        selectedSessionID = session.id
        Task { await session.connect() }
    }

    private func close(_ session: TerminalSession) {
        session.disconnect()
        sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id { selectedSessionID = sessions.last?.id }
    }
}

private struct TerminalPane: View {
    @ObservedObject var session: TerminalSession
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollViewReader { scroll in
                    ScrollView([.vertical, .horizontal]) {
                        Text(ANSIParser.attributed(session.output))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(14)
                            .id("bottom")
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: session.output) { _, _ in scroll.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: proxy.size) { _, size in
                        session.resize(rows: UInt16(max(12, Int(size.height / 18))), columns: UInt16(max(40, Int(size.width / 8))))
                    }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
                TextField("Send command", text: $session.command)
                    .textFieldStyle(.plain)
                    .font(.body.monospaced())
                    .focused($inputFocused)
                    .onSubmit { session.sendCurrentCommand() }
                    .disabled(!session.isConnected)
                Menu {
                    ForEach(session.history.reversed(), id: \.self) { command in
                        Button(command) { session.command = command }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .disabled(session.history.isEmpty)
                Button("Send") { session.sendCurrentCommand() }
                    .disabled(session.command.isEmpty || !session.isConnected)
            }
            .padding(12)
        }
        .onAppear { inputFocused = true }
    }
}
