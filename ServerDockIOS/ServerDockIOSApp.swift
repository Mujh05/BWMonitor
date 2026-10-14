import SwiftUI

// THESIS: ServerDock's servers, live Linux metrics and SFTP at hand on iPhone.
// OWN-WORLD: incumbent teal tint, SF Symbols and semantic native grouped lists.
// STORY: add or import non-secret hosts, verify the SSH fingerprint, then operate.
// FIRST VIEWPORT: server list with explicit connection state; Add in the native toolbar.
// FORM: iOS TabView and NavigationStack; iPad sidebar adaptation, Dynamic Type.
// FINISH: simulator phone/tablet review, honest runtime limits and documented setup.
@main struct ServerDockIOSApp: App {
    @StateObject private var model = IOSAppModel()
    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environmentObject(model)
                .tint(.teal)
                .task { await model.load() }
        }
    }
}

enum MobileTab: Hashable { case servers, monitor, files, terminal, settings }

struct MobileRootView: View {
    @EnvironmentObject private var model: IOSAppModel
    @State private var tab: MobileTab = Self.previewTab

    private static var previewTab: MobileTab {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--demo") else { return .servers }
        if arguments.contains("--demo-monitor") { return .monitor }
        if arguments.contains("--demo-files") { return .files }
        return .servers
    }
    var body: some View {
        TabView(selection: $tab) {
            Tab("服务器", systemImage: "server.rack", value: .servers) { MobileServersView(tab: $tab) }
            Tab("监控", systemImage: "waveform.path.ecg", value: .monitor) { MobileMonitorView() }
            Tab("文件", systemImage: "folder", value: .files) { MobileFilesView() }
            Tab("终端", systemImage: "terminal", value: .terminal) { MobileTerminalView() }
            Tab("设置", systemImage: "gearshape", value: .settings) { MobileSettingsView() }
        }
        .tabViewStyle(.sidebarAdaptable)
        .alert("确认 SSH 主机指纹", isPresented: Binding(get: { model.hostApproval != nil }, set: { if !$0 { model.hostApproval = nil } })) {
            Button("取消", role: .cancel) { model.hostApproval = nil }
            Button("信任并连接") {
                if let approval = model.hostApproval {
                    IOSSSHService.trust(approval)
                    model.hostApproval = nil
                    Task { await model.refresh(approval.server) }
                }
            }
        } message: {
            if let approval = model.hostApproval {
                Text("\(approval.server.host):\(approval.server.port)\n\(approval.fingerprint)\n\n请与服务器控制台提供的指纹核对。只有确认匹配后才信任。")
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { model.globalIssue != nil }, set: { if !$0 { model.globalIssue = nil } })) {
            Button("关闭", role: .cancel) { model.globalIssue = nil }
        } message: { Text(model.globalIssue ?? "") }
    }
}

struct MobileDemoNotice: View {
    @EnvironmentObject private var model: IOSAppModel
    var body: some View {
        if model.isDemo {
            Label("演示模式 · 以下数据为示例，未连接服务器", systemImage: "info.circle")
                .font(.subheadline).foregroundStyle(.secondary)
                .accessibilityIdentifier("demo.notice")
        }
    }
}

struct MobileServerSelector: View {
    @EnvironmentObject private var model: IOSAppModel
    var body: some View {
        Picker("当前服务器", selection: $model.selectedID) {
            ForEach(model.servers) { server in Text(server.name).tag(Optional(server.id)) }
        }
    }
}

struct MobileServersView: View {
    @EnvironmentObject private var model: IOSAppModel
    @Binding var tab: MobileTab
    @State private var editor: Server?
    @State private var deleting: Server?
    @State private var importer = false
    var body: some View {
        NavigationStack {
            Group {
                if model.servers.isEmpty {
                    ContentUnavailableView {
                        Label("连接你的服务器", systemImage: "server.rack")
                    } description: {
                        Text("添加 Linux 服务器即可通过 SSH 查看状态、浏览文件和执行命令。也可导入 Mac 导出的服务器配置。")
                    } actions: {
                        Button("添加服务器") { editor = Server(name: "", host: "") }.buttonStyle(.borderedProminent)
                        Button("导入服务器配置") { importer = true }.buttonStyle(.bordered)
                    }
                } else {
                    List {
                        Section { MobileDemoNotice() }
                        Section("\(model.servers.count) 台服务器") {
                            ForEach(model.servers) { server in
                                Button {
                                    model.selectedID = server.id; tab = .monitor
                                } label: {
                                    HStack(alignment: .top, spacing: 14) {
                                        Image(systemName: "server.rack").foregroundStyle(.tint).font(.title2)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(server.name).font(.headline).foregroundStyle(.primary)
                                            Text(server.provider.rawValue).font(.subheadline).foregroundStyle(.secondary)
                                            Text("\(server.username)@\(server.host)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                            if model.refreshing.contains(server.id) { Text("正在刷新…").font(.caption).foregroundStyle(.secondary) }
                                            else if let issue = model.issues[server.id] { Text(issue).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                                            else if let metric = model.metrics[server.id] {
                                                Text(model.isDemo ? "示例数据" : "上次采样 \(metric.timestamp.formatted(date: .omitted, time: .shortened))")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            } else { Text("尚未连接").font(.caption).foregroundStyle(.secondary) }
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                    }.padding(.vertical, 5)
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing) {
                                    Button("删除", role: .destructive) { deleting = server }
                                    Button("编辑") { editor = server }.tint(.teal)
                                }
                                .contextMenu {
                                    Button("编辑服务器", systemImage: "pencil") { editor = server }
                                    Button("刷新", systemImage: "arrow.clockwise") { Task { await model.refresh(server) } }
                                    Button("删除", systemImage: "trash", role: .destructive) { deleting = server }
                                }
                            }
                        }
                        Section {
                            Label("每台服务器单独连接，刷新全部可同时采样。", systemImage: "network").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .refreshable { await model.refreshAll() }
                }
            }
            .navigationTitle("ServerDock")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("刷新全部", systemImage: "arrow.clockwise") { Task { await model.refreshAll() } }
                        Button("导入服务器配置", systemImage: "square.and.arrow.down") { importer = true }
                    } label: { Image(systemName: "ellipsis.circle") }.disabled(model.isDemo)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("添加服务器", systemImage: "plus") { editor = Server(name: "", host: "") }.disabled(model.isDemo)
                }
            }
            .sheet(item: $editor) { MobileServerEditor(server: $0) }
            .confirmationDialog("删除 \(deleting?.name ?? "服务器")？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除配置和本机保存的凭据", role: .destructive) { if let server = deleting { Task { await model.delete(server) } } }
            } message: { Text("不会删除远程服务器或服务器上的文件。") }
            .fileImporter(isPresented: $importer, allowedContentTypes: [.json]) { result in
                switch result { case .success(let url): Task { await model.importServers(url) }; case .failure(let error): model.report(error) }
            }
        }
    }
}

struct MobileMonitorView: View {
    @EnvironmentObject private var model: IOSAppModel
    @State private var automatic = false
    var body: some View {
        NavigationStack {
            Group {
                if let server = model.selected {
                    List {
                        Section { MobileDemoNotice(); MobileServerSelector() }
                        Section {
                            LabeledContent("平台", value: server.provider.rawValue)
                            LabeledContent("SSH", value: "\(server.host):\(server.port)")
                            if let metrics = model.selectedMetrics { LabeledContent("采样时间", value: metrics.timestamp.formatted(date: .omitted, time: .standard)) }
                            Toggle("自动刷新（10 秒）", isOn: $automatic).disabled(model.isDemo)
                        }
                        if let issue = model.issues[server.id] {
                            Section("连接提示") { Text(issue).foregroundStyle(.orange); Button("重新连接") { Task { await model.refresh(server) } } }
                        }
                        if let metrics = model.selectedMetrics {
                            Section("系统状态") {
                                MobileMeterRow(title: "CPU", fraction: metrics.cpuUsage, detail: "\(metrics.cpuCores) 核")
                                MobileMeterRow(title: "内存", fraction: metrics.memoryPercentage,
                                    detail: "\(MobileFormat.bytes(metrics.memoryUsed)) / \(MobileFormat.bytes(metrics.memoryTotal))")
                                MobileMeterRow(title: "磁盘", fraction: metrics.diskPercentage,
                                    detail: "\(MobileFormat.bytes(metrics.diskUsed)) / \(MobileFormat.bytes(metrics.diskTotal))")
                            }
                            Section("网络 · \(metrics.networkInterface)") {
                                LabeledContent { Text(MobileFormat.rate(metrics.networkDownloadRate)).monospacedDigit() } label: { Label("下载", systemImage: "arrow.down") }
                                LabeledContent { Text(MobileFormat.rate(metrics.networkUploadRate)).monospacedDigit() } label: { Label("上传", systemImage: "arrow.up") }
                                LabeledContent("开机后接收", value: MobileFormat.bytes(metrics.networkReceivedTotal))
                                LabeledContent("开机后发送", value: MobileFormat.bytes(metrics.networkSentTotal))
                            }
                        } else {
                            Section {
                                ContentUnavailableView("尚未采样", systemImage: "waveform.path.ecg", description: Text("点击右上角刷新，首次连接需要核对主机指纹。"))
                            }
                        }
                        if let value = model.selectedTraffic {
                            Section("月度流量") {
                                LabeledContent("已使用", value: MobileFormat.bytes(value.used))
                                if let inbound = value.inbound { LabeledContent("入站", value: MobileFormat.bytes(inbound)) }
                                if let outbound = value.outbound { LabeledContent("出站", value: MobileFormat.bytes(outbound)) }
                                if let quota = value.limit {
                                    LabeledContent("额度", value: MobileFormat.bytes(quota))
                                    if let proportion = value.proportion { MobileMeterRow(title: "额度使用", fraction: proportion, detail: "") }
                                }
                                LabeledContent("重置日期", value: value.nextReset.formatted(date: .abbreviated, time: .omitted))
                                Text(value.source).font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Section("月度流量") {
                                Text(server.provider.supportsTrafficAPI ? "编辑服务器中的平台 API 凭据后，刷新即可读取月度流量。" : "此平台已支持 SSH 系统监控和文件操作。计费月度流量暂未接入；网络累计值来自 Linux 开机计数。")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .refreshable { await model.refresh(server) }
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            if model.refreshing.contains(server.id) { ProgressView() }
                            else { Button("刷新", systemImage: "arrow.clockwise") { Task { await model.refresh(server) } }.disabled(model.isDemo) }
                        }
                    }
                } else { ContentUnavailableView("未选择服务器", systemImage: "server.rack", description: Text("先在“服务器”中添加或选择一台服务器。")) }
            }
            .navigationTitle("监控")
            .task(id: "\(model.selectedID?.uuidString ?? "")-\(automatic)") {
                guard automatic, !model.isDemo else { return }
                do {
                    while !Task.isCancelled {
                        if let server = model.selected { await model.refresh(server) }
                        try await Task.sleep(for: .seconds(10))
                    }
                } catch { /* Changing server or leaving this screen cancels polling normally. */ }
            }
        }
    }
}

struct MobileMeterRow: View {
    let title: String
    let fraction: Double
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title); Spacer(); Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit() }
            ProgressView(value: min(max(fraction, 0), 1))
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 4).accessibilityElement(children: .combine)
    }
}
