import SwiftUI
import UniformTypeIdentifiers

struct MobileServerDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(servers: [Server]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        data = try encoder.encode(servers.map { server in var value = server; value.privateKeyPath = ""; return value })
    }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct MobileSettingsView: View {
    @EnvironmentObject private var model: IOSAppModel
    @State private var document: MobileServerDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var resetServer: Server?
    var body: some View {
        NavigationStack {
            Form {
                Section("配置") {
                    Button("导入服务器配置", systemImage: "square.and.arrow.down") { importing = true }.disabled(model.isDemo)
                    Button("导出服务器配置", systemImage: "square.and.arrow.up") {
                        do { document = try MobileServerDocument(servers: model.servers); exporting = true }
                        catch { model.report(error) }
                    }.disabled(model.servers.isEmpty || model.isDemo)
                    Text("JSON 只包含服务器设置，不含密码、私钥、API Token。导入后需要在此设备单独填写凭据；已存在的服务器不会被覆盖。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.servers.isEmpty && !model.isDemo {
                    Section("SSH 主机信任") {
                        ForEach(model.servers) { server in
                            Button { resetServer = server } label: { LabeledContent(server.name, value: "重置信任") }
                        }
                    }
                }
                Section("平台支持") {
                    LabeledContent("月度流量 API", value: "AWS、KiwiVM、Vultr、Hetzner")
                    Text("DigitalOcean、阿里云、腾讯云、Oracle Cloud 及其他 Linux 服务器支持 SSH 系统监控、SFTP 文件和远程命令。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("关于") {
                    LabeledContent("ServerDock for iOS", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")
                    Text("直接从 iPhone / iPad 连接服务器，无需 Mac 中转。iOS 进入后台后不保证持续监控；回到前台可手动刷新。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Link("SSH 库：Citadel", destination: URL(string: "https://github.com/orlandos-nl/Citadel")!)
                    if model.isDemo { Button("退出演示模式") { Task { await model.leaveDemo() } } }
                }
            }
            .navigationTitle("设置")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                switch result { case .success(let url): Task { await model.importServers(url) }; case .failure(let error): model.report(error) }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "ServerDock-servers") { result in
                if case .failure(let error) = result { model.report(error) }
            }
            .confirmationDialog("重置 \(resetServer?.name ?? "") 的主机信任？", isPresented: Binding(get: { resetServer != nil }, set: { if !$0 { resetServer = nil } }), titleVisibility: .visible) {
                Button("重置主机信任", role: .destructive) { if let server = resetServer { IOSSSHService.forgetTrust(server) } }
            } message: { Text("下一次连接需要重新核对 SHA256 指纹。仅在已确认服务器更换主机密钥时使用。") }
        }
    }
}
