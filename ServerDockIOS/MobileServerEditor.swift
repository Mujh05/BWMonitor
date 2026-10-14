import SwiftUI
import UniformTypeIdentifiers

struct MobileServerEditor: View {
    @EnvironmentObject private var model: IOSAppModel
    @Environment(\.dismiss) private var dismiss
    @State var server: Server
    @State private var password = ""
    @State private var key = ""
    @State private var passphrase = ""
    @State private var apiKey = ""
    @State private var awsID = ""
    @State private var awsSecret = ""
    @State private var awsToken = ""
    @State private var quota = ""
    @State private var importingKey = false
    @State private var saving = false
    @State private var issue: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    TextField("名称", text: $server.name)
                    Picker("平台", selection: $server.provider) {
                        ForEach(ServerProvider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    TextField("IP 地址或主机名", text: $server.host).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("SSH 端口", value: $server.port, format: .number.grouping(.never)).keyboardType(.numberPad)
                    TextField("用户名", text: $server.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Picker("认证方式", selection: $server.authentication) {
                        Text("私钥").tag(SSHAuthentication.key)
                        Text("密码").tag(SSHAuthentication.password)
                    }.pickerStyle(.segmented)
                    if server.authentication == .password {
                        SecureField(model.keychain.contains(server.id, kind: .sshPassword) ? "已保存密码，留空保留" : "SSH 密码", text: $password)
                    } else {
                        Button("从“文件”导入私钥", systemImage: "doc.badge.plus") { importingKey = true }
                        DisclosureGroup("或粘贴 OpenSSH 私钥") {
                            TextEditor(text: $key).font(.caption.monospaced()).frame(minHeight: 140)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .privacySensitive()
                        }
                        if !key.isEmpty { Label("已选择私钥，保存时写入钥匙串", systemImage: "key.fill").font(.caption).foregroundStyle(.secondary) }
                        else if (try? MobileKeyStore.key(for: server.id)) != nil {
                            Label("此设备已保存私钥", systemImage: "key.fill").font(.caption).foregroundStyle(.secondary)
                        }
                        SecureField(model.keychain.contains(server.id, kind: .privateKeyPassphrase) ? "已保存密钥密码，留空保留" : "私钥密码（可选）", text: $passphrase)
                    }
                } header: { Text("SSH 认证") } footer: {
                    Text("支持 OpenSSH RSA、Ed25519 和未加密 RSA PEM。RSA 登录需服务器允许 ssh-rsa；现代服务器可优先使用 Ed25519。凭据仅存此设备钥匙串。首次连接需确认主机指纹。")
                }
                if server.provider == .awsLightsail {
                    Section("AWS Lightsail 月度流量") {
                        TextField("实例名称", text: $server.awsInstanceName).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("区域，例如 ap-southeast-1", text: $server.awsRegion).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField(model.keychain.contains(server.id, kind: .awsAccessKeyID) ? "Access Key ID 已保存，留空保留" : "Access Key ID", text: $awsID)
                        SecureField(model.keychain.contains(server.id, kind: .awsSecretAccessKey) ? "Secret Access Key 已保存，留空保留" : "Secret Access Key", text: $awsSecret)
                        SecureField("Session Token（可选，留空保留）", text: $awsToken)
                        TextField("月度额度 GB（可选）", text: $quota).keyboardType(.decimalPad)
                        Text("使用已有的只读 IAM 凭据。所需操作：GetInstance、GetBundles、GetInstanceMetricData。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if server.provider == .bandwagonHost {
                    Section("KiwiVM 月度流量") {
                        TextField("VEID", text: $server.veid).keyboardType(.numberPad)
                        SecureField(model.keychain.contains(server.id, kind: .kiwiAPIKey) ? "API Key 已保存，留空保留" : "API Key", text: $apiKey)
                    }
                } else if server.provider.supportsCloudTraffic {
                    Section("\(server.provider.rawValue) 月度流量") {
                        TextField("实例 ID", text: $server.cloudInstanceID).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField(model.keychain.contains(server.id, kind: .cloudAPIKey) ? "API Token 已保存，留空保留" : "只读 API Token", text: $apiKey)
                        TextField("月度额度 GB（可选）", text: $quota).keyboardType(.decimalPad)
                        Text("该平台按出站流量显示计费使用量。请使用范围最小的只读 Token。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section { Text("此平台支持 SSH 监控、SFTP 文件和远程命令。月度计费流量 API 暂未接入。") .font(.subheadline).foregroundStyle(.secondary) }
                }
                if let issue { Section("请检查") { Text(issue).foregroundStyle(.orange) } }
            }
            .navigationTitle(model.servers.contains(where: { $0.id == server.id }) ? "编辑服务器" : "添加服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }.disabled(saving || !valid)
                }
            }
            .interactiveDismissDisabled(saving)
            .fileImporter(isPresented: $importingKey, allowedContentTypes: [.data, .plainText]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.fileSizeKey])
                    guard (values.fileSize ?? 0) < 1_000_000 else { throw MobileConnectionError.unsupportedKey }
                    key = try String(contentsOf: url, encoding: .utf8)
                } catch { issue = error.localizedDescription }
            }
            .onAppear {
                quota = (server.provider == .awsLightsail ? server.awsMonthlyTransferOverrideGB : server.cloudMonthlyTransferOverrideGB).map { String($0) } ?? ""
                server.privateKeyPath = ""
            }
            .onChange(of: server.provider) { _, _ in
                apiKey = ""; awsID = ""; awsSecret = ""; awsToken = ""; quota = ""
                server.cloudInstanceID = ""; server.cloudMonthlyTransferOverrideGB = nil
            }
        }
    }

    private var valid: Bool {
        let normalized = server.normalized
        return normalized.isValid && Server.isValidHost(normalized.host) && Server.isValidUsername(normalized.username)
    }

    private func save() async {
        saving = true; issue = nil
        defer { saving = false }
        do {
            let trimmedQuota = quota.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedQuota.isEmpty {
                guard let number = Double(trimmedQuota), number.isFinite, number > 0 else {
                    issue = "月度额度需为大于 0 的 GB 数值。"; return
                }
            }
            if server.provider == .awsLightsail { server.awsMonthlyTransferOverrideGB = Double(trimmedQuota) }
            else { server.cloudMonthlyTransferOverrideGB = Double(trimmedQuota) }
            var secrets: [SecretKind: String] = [.sshPassword: password, .privateKeyPassphrase: passphrase,
                .awsAccessKeyID: awsID.trimmingCharacters(in: .whitespacesAndNewlines),
                .awsSecretAccessKey: awsSecret.trimmingCharacters(in: .whitespacesAndNewlines),
                .awsSessionToken: awsToken.trimmingCharacters(in: .whitespacesAndNewlines)]
            secrets[server.provider == .bandwagonHost ? .kiwiAPIKey : .cloudAPIKey] = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            try await model.save(server, secrets: secrets, privateKey: key)
            dismiss()
        } catch { issue = error.localizedDescription }
    }
}
