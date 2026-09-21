import AppKit
import SwiftUI

/// Adds or edits a server, including everything needed to sign in:
/// verifying the host key, choosing or creating an SSH key, installing it
/// on the server, and testing the connection.
struct ServerEditorView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ServerEditorModel
    @State private var showingInstallSheet = false
    @State private var showingPasteSheet = false
    @State private var showingKeyLoginSheet = false

    init(server: Server?, state: AppState) {
        _model = StateObject(wrappedValue: ServerEditorModel(server: server, state: state))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                Form {
                    serverSection
                    hostKeySection
                    signInSection
                    if model.draft.provider == .bandwagonHost { kiwiSection }
                    if model.test != .idle { testSection.id("test") }
                }
                .formStyle(.grouped)
                .onChange(of: model.test) { _, test in
                    // Bring the result into view; the button is at the bottom.
                    if test != .idle {
                        withAnimation { proxy.scrollTo("test", anchor: .bottom) }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 700)
        .sheet(isPresented: $showingInstallSheet) {
            KeyInstallSheet(model: model, mode: .install)
        }
        .sheet(isPresented: $showingKeyLoginSheet) {
            KeyInstallSheet(model: model, mode: .setUpKeyLogin)
        }
        .sheet(isPresented: $showingPasteSheet) {
            PasteKeySheet(model: model)
        }
    }

    // MARK: Sections

    private var serverSection: some View {
        Section("Server") {
            TextField("Display name", text: $model.draft.name, prompt: Text("My VPS"))
            TextField("Host or IP", text: $model.draft.host, prompt: Text("203.0.113.10"))
            TextField("SSH port", value: $model.draft.port, format: .number.grouping(.never))
            TextField("SSH username", text: $model.draft.username)
            Picker("Provider", selection: $model.draft.provider) {
                ForEach(ServerProvider.allCases, id: \.self) {
                    Text(LocalizedStringKey($0.rawValue)).tag($0)
                }
            }
        }
    }

    private var hostKeySection: some View {
        Section {
            switch model.hostKey {
            case .notChecked:
                HStack {
                    Label("Not verified yet", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Host Key") { Task { await model.checkHostKey() } }
                        .disabled(!model.canConnect)
                }
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Contacting the server…")
                        .foregroundStyle(.secondary)
                }
            case let .awaitingTrust(identity):
                VStack(alignment: .leading, spacing: 8) {
                    Label("New server. Confirm its fingerprint.", systemImage: "questionmark.diamond.fill")
                        .foregroundStyle(.orange)
                    FingerprintList(keys: identity.keys)
                    Text("To be sure, run `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` in your provider's web console and compare the result.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Cancel") { model.forgetHostKey() }
                        Button("Trust") { model.trust(identity) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            case let .trusted(keys):
                HStack(alignment: .firstTextBaseline) {
                    Label("Trusted", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Menu("Options") {
                        Button("Check Again") { Task { await model.checkHostKey() } }
                        Button("Forget Host Key", role: .destructive) { model.forgetHostKey() }
                    }
                    .fixedSize()
                }
                FingerprintList(keys: Array(SSHHostIdentity(host: "", keys: keys).keys.prefix(1)))
            case let .changed(saved, received):
                VStack(alignment: .leading, spacing: 8) {
                    Label("The server's host key changed", systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.headline)
                    Text("This is expected after reinstalling the system. Otherwise someone may be intercepting the connection; do not trust the new key.")
                        .font(.callout)
                    Text("Saved").font(.caption.weight(.semibold))
                    FingerprintList(keys: saved)
                    Text("Now").font(.caption.weight(.semibold))
                    FingerprintList(keys: received.keys)
                    HStack {
                        Spacer()
                        Button("Trust New Key", role: .destructive) { model.trust(received) }
                    }
                }
            case let .failed(message):
                HStack(alignment: .firstTextBaseline) {
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Try Again") { Task { await model.checkHostKey() } }
                }
            }
        } header: {
            Text("Host Key")
        } footer: {
            Text("The host key proves you are talking to your server. BWMonitor refuses to connect if it ever changes.")
        }
    }

    private var signInSection: some View {
        Section {
            Picker("Sign in with", selection: $model.draft.authentication) {
                ForEach(SSHAuthentication.allCases, id: \.self) {
                    Text(LocalizedStringKey($0.titleKey)).tag($0)
                }
            }
            .pickerStyle(.segmented)

            if model.draft.authentication == .key {
                keyRows
            } else {
                passwordRows
            }
        } header: {
            Text("Sign-In")
        } footer: {
            Text("Passwords and passphrases are kept only in the macOS Keychain. Only the ones the chosen method needs are kept.")
        }
    }

    @ViewBuilder
    private var keyRows: some View {
        LabeledContent("Key") {
            Menu {
                Section {
                    Button {
                        Task { await model.useAppKey() }
                    } label: {
                        Text(model.appKey == nil ? "Create BWMonitor Key" : "BWMonitor Key")
                    }
                }
                if !model.discoveredKeys.isEmpty {
                    Section("In ~/.ssh") {
                        ForEach(model.discoveredKeys) { key in
                            Button("\(key.displayPath)  (\(key.displayAlgorithm))") { model.useKey(at: key.path) }
                        }
                    }
                }
                Section {
                    Button("Keys in SSH Agent") { model.useAgent() }
                }
                Section {
                    Button("Choose Key File…") { chooseKeyFile() }
                    Button("Paste Private Key…") { showingPasteSheet = true }
                }
            } label: {
                Text(keyTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 320, alignment: .trailing)
            .help(model.draft.privateKeyPath)
        }

        if model.isUsingAgent {
            Text("ssh uses the keys loaded in your SSH agent (ssh-add) and the default keys in ~/.ssh.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if model.appKeyMissing {
            HStack {
                Text("BWMonitor creates its own key and keeps it on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Create Key") { Task { await model.createAppKey() } }
                    .disabled(model.isWorking)
            }
        } else if let info = model.keyInfo {
            LabeledContent("Fingerprint") {
                Text("\(info.displayAlgorithm)  \(info.fingerprint ?? "—")")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if info.isEncrypted {
                SecureField(
                    "Passphrase",
                    text: $model.passphrase,
                    prompt: Text(model.hasSavedPassphrase ? "Saved in Keychain" : "Required")
                )
            }
            HStack {
                Button("Copy Public Key") { model.copyPublicKey() }
                    .disabled(info.publicKey == nil)
                Button("Show in Finder") { model.revealKeyInFinder() }
                Spacer()
                Button("Install on Server…") { showingInstallSheet = true }
                    .disabled(info.publicKey == nil || !model.isHostTrusted || model.isWorking)
                    .help(model.isHostTrusted ? "" : NSLocalizedString("Trust the host key first.", comment: "Help tag"))
            }
        }

        if model.keyHasLoosePermissions {
            HStack {
                Label("Other users can read this key file, so SSH refuses it.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Fix") { model.fixKeyPermissions() }
            }
        }
        if let problem = model.keyProblem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var passwordRows: some View {
        SecureField(
            "Password",
            text: $model.password,
            prompt: Text(model.hasSavedPassword ? "Saved in Keychain" : "Required")
        )
        VStack(alignment: .leading, spacing: 8) {
            Label("Key login is safer and works without a saved password.", systemImage: "key.fill")
                .font(.callout.weight(.medium))
            Text("BWMonitor can create its own key, add it to the server using this password once, and switch to key login.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Set Up Key Login…") { showingKeyLoginSheet = true }
                    .disabled(!model.isHostTrusted || model.isWorking)
                    .help(model.isHostTrusted ? "" : NSLocalizedString("Trust the host key first.", comment: "Help tag"))
            }
        }
        .padding(.vertical, 2)
    }

    private var kiwiSection: some View {
        Section {
            TextField("VEID", text: $model.draft.veid)
            SecureField(
                "API key",
                text: $model.apiKey,
                prompt: Text(model.hasSavedAPIKey ? "Saved in Keychain" : "Optional")
            )
        } header: {
            Text("KiwiVM")
        } footer: {
            Text("Find both in the KiwiVM control panel under API. They are used only to read monthly traffic.")
        }
    }

    private var testSection: some View {
        Section("Connection Test") {
            switch model.test {
            case .idle:
                EmptyView()
            case let .running(message):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(message).foregroundStyle(.secondary)
                }
            case let .succeeded(message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
            case let .failed(message, action):
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    if let action {
                        HStack {
                            Spacer()
                            actionButton(action)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: ServerEditorModel.EditorAction) -> some View {
        switch action {
        case .checkHostKey:
            Button("Check Host Key") { Task { await model.checkHostKey() } }
        case .installKey:
            Button("Install on Server…") { showingInstallSheet = true }
                .disabled(model.keyInfo?.publicKey == nil || !model.isHostTrusted)
        case .fixPermissions:
            Button("Fix Key Permissions") { model.fixKeyPermissions() }
        case .chooseKey:
            Button("Choose Key File…") { chooseKeyFile() }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Test Connection") { Task { await model.testConnection() } }
                .disabled(!model.canConnect || model.isWorking)
            switch model.test {
            case .running:
                ProgressView().controlSize(.small)
            case .succeeded:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Label("Connection failed", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            case .idle:
                EmptyView()
            }
            if let error = model.saveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .font(.callout)
            }
            Spacer()
            Button("Cancel", role: .cancel) {
                model.discard()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Save") {
                Task { if await model.save() { dismiss() } }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.validationMessage != nil || model.isWorking)
        }
        .padding()
    }

    // MARK: Helpers

    private var keyTitle: String {
        if model.isUsingAgent { return NSLocalizedString("Keys in SSH Agent", comment: "SSH key menu") }
        if model.isUsingAppKey { return NSLocalizedString("BWMonitor Key", comment: "SSH key menu") }
        return NSString(string: model.draft.privateKeyPath).abbreviatingWithTildeInPath
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Choose an SSH Private Key", comment: "Open panel title")
        panel.message = NSLocalizedString(
            "Choose the private key, not the .pub file. Press ⌘⇧. to show hidden files.",
            comment: "Open panel message"
        )
        panel.prompt = NSLocalizedString("Choose", comment: "Open panel button")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            model.useKey(at: url.path)
        }
    }
}

private struct FingerprintList: View {
    let keys: [SSHHostKey]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(keys, id: \.self) { key in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(key.displayType)
                        .font(.caption.weight(.semibold))
                        .frame(width: 58, alignment: .leading)
                    Text(key.fingerprint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// Installs the selected key on the server with the password, or sets up
/// key login from password mode.
private struct KeyInstallSheet: View {
    enum Mode {
        case install
        case setUpKeyLogin
    }

    @ObservedObject var model: ServerEditorModel
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var finished = false

    private var canUseSavedPassword: Bool {
        model.hasSavedPassword || !model.password.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .install ? "Install Public Key" : "Set Up Key Login")
                .font(.title3.weight(.semibold))
            Text(
                String(
                    format: NSLocalizedString(
                        "BWMonitor signs in to %@ once with the password and adds the key to ~/.ssh/authorized_keys. Keys already on the server stay as they are.",
                        comment: "Key installation explanation"
                    ),
                    "\(model.draft.username)@\(model.draft.host)"
                )
            )
            .fixedSize(horizontal: false, vertical: true)
            if mode == .install, let key = model.keyInfo?.publicKey {
                Text(key)
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            SecureField(
                String(format: NSLocalizedString("Password for %@", comment: "Password field"), model.draft.username),
                text: $password,
                prompt: Text(canUseSavedPassword ? "Leave blank to use the saved password" : "Required")
            )
            .textFieldStyle(.roundedBorder)
            .disabled(model.isWorking || finished)

            status

            HStack {
                Spacer()
                if finished {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.isWorking)
                    Button(mode == .install ? "Install" : "Set Up") {
                        Task {
                            finished = mode == .install
                                ? await model.installKey(password: password)
                                : await model.setUpKeyLogin(password: password)
                            password = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isWorking || (password.isEmpty && !canUseSavedPassword))
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder
    private var status: some View {
        switch model.test {
        case let .running(message) where model.isWorking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message).foregroundStyle(.secondary)
            }
        case let .succeeded(message) where finished:
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message, _) where !model.isWorking:
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }
}

private struct PasteKeySheet: View {
    @ObservedObject var model: ServerEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste Private Key")
                .font(.title3.weight(.semibold))
            Text("Paste the whole key, including the BEGIN and END lines. BWMonitor saves it in its own folder, readable only by you.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.caption.monospaced())
                .frame(height: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Paste from Clipboard") {
                    text = NSPasteboard.general.string(forType: .string) ?? text
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    do {
                        try model.importPastedKey(text)
                        text = ""
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
