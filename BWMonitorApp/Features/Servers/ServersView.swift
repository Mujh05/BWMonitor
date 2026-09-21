import SwiftUI

struct ServersView: View {
    @EnvironmentObject private var state: AppState
    @Binding var showingAddServer: Bool
    @State private var editingServer: Server?
    @State private var deletingServer: Server?
    @State private var pendingTrust: (Server, SSHHostIdentity)?
    @State private var verificationMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if state.servers.isEmpty {
                EmptySelectionView(
                    title: LocalizedStringKey("No servers"),
                    message: LocalizedStringKey("Add a VPS to begin monitoring."),
                    action: { showingAddServer = true }
                )
            } else {
                List(state.servers, selection: $state.selectedServerID) { server in
                    ServerRow(server: server, metrics: state.metricsByServer[server.id])
                        .tag(server.id)
                        .contextMenu {
                            Button("Edit") { editingServer = server }
                            Button("Verify Host Key") { verify(server) }
                            Divider()
                            Button("Delete", role: .destructive) { deletingServer = server }
                        }
                }
            }
        }
        .navigationTitle("Servers")
        .toolbar {
            ToolbarItemGroup {
                Button("Add Server", systemImage: "plus") { showingAddServer = true }
                Button("Edit Server", systemImage: "pencil") { editingServer = state.selectedServer }
                    .disabled(state.selectedServer == nil)
                Button("Verify Host Key", systemImage: "lock.shield") {
                    if let server = state.selectedServer { verify(server) }
                }
                .disabled(state.selectedServer == nil)
            }
        }
        .sheet(item: $editingServer) { server in
            ServerEditorView(server: server)
                .environmentObject(state)
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
        .alert("Trust SSH Host?", isPresented: Binding(
            get: { pendingTrust != nil },
            set: { if !$0 { pendingTrust = nil } }
        ), presenting: pendingTrust) { value in
            Button("Trust") {
                do {
                    try state.trustHostKey(value.1, for: value.0)
                    verificationMessage = String(
                        format: NSLocalizedString("Host key trusted for %@.", comment: "Trusted host message"),
                        value.0.name
                    )
                } catch {
                    state.lastError = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { value in
            Text(
                String(
                    format: NSLocalizedString(
                        "%1$@\n%2$@\n%3$@\n\nConfirm this fingerprint through your provider before trusting it.",
                        comment: "SSH host trust confirmation"
                    ),
                    value.0.host,
                    value.1.keyType,
                    value.1.fingerprint
                )
            )
        }
        .alert("SSH Verification", isPresented: Binding(
            get: { verificationMessage != nil },
            set: { if !$0 { verificationMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(verificationMessage ?? "")
        }
    }

    private func verify(_ server: Server) {
        Task {
            do {
                switch try await state.inspectHostKey(server) {
                case let .unknown(identity):
                    pendingTrust = (server, identity)
                case let .trusted(identity):
                    verificationMessage = String(
                        format: NSLocalizedString("Host key matches %@.", comment: "Known host match"),
                        identity.fingerprint
                    )
                case let .changed(expected, received):
                    verificationMessage = String(
                        format: NSLocalizedString(
                            "Connection blocked. The saved key (%1$@) does not match the server (%2$@).",
                            comment: "SSH host key mismatch"
                        ),
                        expected,
                        received.fingerprint
                    )
                }
            } catch {
                state.lastError = error.localizedDescription
            }
        }
    }
}

private struct ServerRow: View {
    let server: Server
    let metrics: ServerMetrics?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundStyle(metrics == nil ? Color.secondary : Color.accentColor)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(server.name)
                        .font(.headline)
                    Circle()
                        .fill(metrics == nil ? Color.secondary : Color.green)
                        .frame(width: 7, height: 7)
                }
                Text("\(server.username)@\(server.host):\(server.port)")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(LocalizedStringKey(server.provider.rawValue))
                Text(server.operatingSystem)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(.vertical, 6)
    }
}

struct ServerEditorView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Server
    @State private var apiKey = ""
    @State private var password = ""
    @State private var keyPassphrase = ""

    init(server: Server?) {
        _draft = State(initialValue: server ?? Server(name: "", host: ""))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Server") {
                    TextField("Display name", text: $draft.name)
                    TextField("Host or IP", text: $draft.host)
                    TextField("SSH username", text: $draft.username)
                    TextField("SSH port", value: $draft.port, format: .number)
                    Picker("Provider", selection: $draft.provider) {
                        ForEach(ServerProvider.allCases, id: \.self) {
                            Text(LocalizedStringKey($0.rawValue)).tag($0)
                        }
                    }
                    TextField("Operating system", text: $draft.operatingSystem)
                }

                Section("SSH Authentication") {
                    Picker("Method", selection: $draft.authentication) {
                        ForEach(SSHAuthentication.allCases, id: \.self) {
                            Text(LocalizedStringKey($0.rawValue)).tag($0)
                        }
                    }
                    if draft.authentication == .key {
                        TextField("Private key path (optional when using SSH agent)", text: $draft.privateKeyPath)
                        SecureField("Private key passphrase (leave blank to keep existing)", text: $keyPassphrase)
                    } else {
                        SecureField("SSH password (leave blank to keep existing)", text: $password)
                    }
                    Text("Private-key paths are optional with SSH Agent; blank secrets keep saved values.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if draft.provider == .bandwagonHost {
                    Section("KiwiVM") {
                        TextField("VEID", text: $draft.veid)
                        SecureField("API key (leave blank to keep existing)", text: $apiKey)
                        Text("Secrets are stored only in macOS Keychain.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save") {
                    Task {
                        if await state.saveServer(draft, apiKey: apiKey, password: password, keyPassphrase: keyPassphrase) {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!draft.isValid)
            }
            .padding()
        }
        .frame(width: 680, height: 610)
    }
}
