import SwiftUI

struct MobileTerminalView: View {
    @EnvironmentObject private var model: IOSAppModel
    @State private var command = ""
    @State private var output = ""
    @State private var busy = false
    @State private var running: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            List {
                Section { MobileDemoNotice(); if !model.servers.isEmpty { MobileServerSelector() } }
                if let server = model.selected {
                    Section("远程命令") {
                        TextField("例如：uname -a", text: $command, axis: .vertical)
                            .font(.body.monospaced()).lineLimit(2...6)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        HStack {
                            Button { run(server) } label: { Label("执行", systemImage: "play.fill") }
                                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy || model.isDemo)
                            Spacer()
                            if busy {
                                ProgressView()
                                Button("停止", role: .destructive) { running?.cancel() }
                            } else { Button("清空") { output = "" }.disabled(output.isEmpty) }
                        }
                    }
                    Section("输出") {
                        if output.isEmpty { Text("执行结果将显示在这里。密码保存在本机钥匙串，不需要写进命令。") .foregroundStyle(.secondary) }
                        else { Text(output).font(.footnote.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                    Section {
                        Text("此版本执行一次性 SSH 命令，最长 30 秒、输出最多 2 MB。暂不支持 vim、top 等交互式终端程序。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else { ContentUnavailableView("未选择服务器", systemImage: "terminal", description: Text("先在“服务器”中添加或选择一台服务器。")) }
            }
            .navigationTitle("终端")
            .onChange(of: model.selectedID) { _, _ in running?.cancel(); output = "" }
            .onDisappear { running?.cancel() }
        }
    }

    private func run(_ server: Server) {
        let submitted = command
        busy = true
        running = Task {
            defer { busy = false; running = nil }
            do {
                let result = try await model.ssh.execute(submitted, on: server)
                guard model.selectedID == server.id else { return }
                output += "$ \(submitted)\n\(result)\n"
                if output.utf8.count > 2_000_000 { output = String(output.suffix(500_000)) }
            } catch {
                if error is CancellationError { return }
                if error is HostKeyApproval { model.report(error, server: server) }
                else if model.selectedID == server.id { output += "\n\(error.localizedDescription)\n" }
            }
        }
    }
}
