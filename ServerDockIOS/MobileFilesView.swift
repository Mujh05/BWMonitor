import SwiftUI
import UniformTypeIdentifiers

struct MobileFilesView: View {
    @EnvironmentObject private var model: IOSAppModel
    @State private var path = "."
    @State private var typedPath = ""
    @State private var entries: [RemoteFileEntry] = []
    @State private var busy = false
    @State private var importer = false
    @State private var issue: String?
    @State private var notice: String?
    @State private var downloaded: URL?
    @State private var showHidden = false
    var body: some View {
        NavigationStack {
            Group {
                if let server = model.selected {
                    List {
                        Section { MobileDemoNotice(); MobileServerSelector() }
                        Section("远程目录") {
                            HStack {
                                TextField("输入绝对路径或 .", text: $typedPath).textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .onSubmit { Task { await load(typedPath, server: server) } }
                                Button("前往") { Task { await load(typedPath, server: server) } }.disabled(busy || model.isDemo)
                            }
                            if path != "." { Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            Toggle("显示隐藏文件", isOn: $showHidden)
                        }
                        if let issue { Section("连接提示") { Text(issue).foregroundStyle(.orange) } }
                        if let notice { Section { Label(notice, systemImage: "checkmark.circle").foregroundStyle(.secondary) } }
                        if let downloaded {
                            Section("下载完成") {
                                ShareLink(item: downloaded) { Label("保存或分享 \(downloaded.lastPathComponent)", systemImage: "square.and.arrow.up") }
                            }
                        }
                        Section("文件与文件夹") {
                            if path != "." && path != "/" {
                                Button { Task { await load((path as NSString).deletingLastPathComponent, server: server) } }
                                    label: { Label("上一级", systemImage: "arrow.turn.up.left") }.disabled(busy || model.isDemo)
                            }
                            ForEach(entries.filter { showHidden || !$0.name.hasPrefix(".") }) { entry in
                                Button {
                                    if entry.kind == .directory { Task { await load(entry.path, server: server) } }
                                    else if entry.kind == .file { Task { await download(entry, server: server) } }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: entry.kind == .directory ? "folder.fill" : entry.kind == .symbolicLink ? "link" : "doc")
                                            .foregroundStyle(entry.kind == .directory ? Color.teal : Color.secondary)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(entry.name).foregroundStyle(.primary).lineLimit(2)
                                            HStack {
                                                if entry.kind != .directory { Text(MobileFormat.bytes(entry.size)) }
                                                if let date = entry.modifiedAt { Text(date, style: .date) }
                                                if entry.kind == .symbolicLink { Text("符号链接") }
                                            }.font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: entry.kind == .directory ? "chevron.right" : "arrow.down.circle")
                                            .foregroundStyle(.tertiary)
                                    }.padding(.vertical, 5)
                                }.buttonStyle(.plain).disabled(busy || model.isDemo || (entry.kind != .directory && entry.kind != .file))
                            }
                            if entries.isEmpty && !busy {
                                Text(path == "." ? "点击刷新读取远程目录。" : "此文件夹为空。")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Section {
                            Text("通过 SFTP 加密传输。上传到当前文件夹，同名文件会保留；请先在本机重命名。点击普通文件可下载，再保存到“文件”或分享。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .refreshable { await load(path, server: server) }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            if busy { ProgressView() }
                            else { Button("刷新", systemImage: "arrow.clockwise") { Task { await load(path, server: server) } }.disabled(model.isDemo) }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("上传文件", systemImage: "square.and.arrow.up") { importer = true }
                                .disabled(busy || path == "." || model.isDemo)
                        }
                    }
                    .fileImporter(isPresented: $importer, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                        switch result {
                        case .success(let urls): Task { await upload(urls, server: server) }
                        case .failure(let error): model.report(error)
                        }
                    }
                } else { ContentUnavailableView("未选择服务器", systemImage: "folder", description: Text("先添加或选择服务器，再通过 SFTP 浏览远程文件。")) }
            }
            .navigationTitle("文件")
            .onChange(of: model.selectedID) { _, _ in path = "."; typedPath = ""; entries = []; downloaded = nil; issue = nil; notice = nil }
            .task {
                if model.isDemo {
                    path = "/home/ubuntu"; typedPath = path
                    entries = [RemoteFileEntry(name: "projects", path: path + "/projects", kind: .directory, size: 0),
                               RemoteFileEntry(name: "backups", path: path + "/backups", kind: .directory, size: 0),
                               RemoteFileEntry(name: "README.txt", path: path + "/README.txt", kind: .file, size: 2048)]
                }
            }
        }
    }

    private func load(_ directory: String, server: Server) async {
        guard !busy, !model.isDemo else { return }
        busy = true; issue = nil; notice = nil
        defer { busy = false }
        do {
            let result = try await model.ssh.directory(directory.isEmpty ? "." : directory, on: server)
            guard model.selectedID == server.id else { return }
            path = result.path; typedPath = result.path; entries = result.entries
        } catch { handle(error, server: server) }
    }

    private func upload(_ urls: [URL], server: Server) async {
        guard !busy, !model.isDemo else { return }
        busy = true; issue = nil; notice = nil
        let destination = path
        var completed = 0
        do {
            for url in urls {
                guard model.selectedID == server.id, model.servers.contains(server) else { break }
                try await model.ssh.upload(url, directory: destination, on: server); completed += 1
            }
            guard model.selectedID == server.id, model.servers.contains(server) else { busy = false; return }
            let result = try await model.ssh.directory(destination, on: server)
            if model.selectedID == server.id { entries = result.entries; notice = "已上传 \(completed) 个文件。" }
        } catch {
            handle(error, server: server)
            if completed > 0, model.selectedID == server.id, model.servers.contains(server) { notice = "已上传 \(completed) 个文件；后续上传未完成。" }
        }
        busy = false
    }

    private func download(_ entry: RemoteFileEntry, server: Server) async {
        guard !busy, !model.isDemo else { return }
        busy = true; issue = nil; notice = nil
        defer { busy = false }
        do { let url = try await model.ssh.download(entry, on: server); if model.selectedID == server.id { downloaded = url } }
        catch { handle(error, server: server) }
    }

    private func handle(_ error: Error, server: Server) {
        guard model.selectedID == server.id, model.servers.contains(server) else { return }
        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        if error is HostKeyApproval { model.report(error, server: server) }
        else { issue = error.localizedDescription }
    }
}
