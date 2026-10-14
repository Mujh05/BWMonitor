import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserView: View {
    @EnvironmentObject private var state: AppState
    @State private var directory = ""
    @State private var location = ""
    @State private var entries: [RemoteFileEntry] = []
    @State private var issue: String?
    @State private var status: String?
    @State private var showHidden = false
    @State private var isLoading = false
    @State private var transferring = false
    @State private var dropTargeted = false
    @State private var transferTask: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var transferID = UUID()

    private var browserServer: Server? {
        var server = state.selectedServer
        server?.operatingSystem = ""
        return server
    }

    private func isCurrent(_ server: Server) -> Bool {
        var snapshot = server
        snapshot.operatingSystem = ""
        return browserServer == snapshot
    }

    private var visibleEntries: [RemoteFileEntry] {
        showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let server = state.selectedServer {
                locationBar(server)
                Divider()
                if let issue {
                    ErrorBanner(message: issue) { self.issue = nil }.padding(12)
                }
                if isLoading && entries.isEmpty {
                    ProgressView("Loading folder…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visibleEntries.isEmpty {
                    ContentUnavailableView("Empty folder", systemImage: "folder",
                                           description: Text("Upload files or drag files here from Finder."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(visibleEntries) { entry in
                        fileRow(entry, server: server)
                    }
                    .listStyle(.inset)
                }
                Divider()
                footer
            } else {
                ContentUnavailableView("Select a server", systemImage: "server.rack",
                                       description: Text("Choose a server to browse its folders."))
            }
        }
        .navigationTitle("Files")
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !transferring, !isLoading, !directory.isEmpty, state.selectedServer != nil else { return false }
            startUpload(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .task(id: browserServer) {
            transferID = UUID()
            transferTask?.cancel()
            transferring = false
            directory = ""
            location = ""
            entries = []
            issue = nil
            status = nil
            await load("")
        }
        .onDisappear { transferID = UUID(); transferTask?.cancel(); transferring = false }
    }

    private func locationBar(_ server: Server) -> some View {
        HStack(spacing: 10) {
            Button("Home", systemImage: "house") { Task { await load("") } }
                .labelStyle(.iconOnly)
            Button("Parent Folder", systemImage: "arrow.up") {
                Task { await load((directory as NSString).deletingLastPathComponent) }
            }
            .labelStyle(.iconOnly)
            .disabled(directory.isEmpty || directory == "/")
            TextField("Folder path", text: $location)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await load(location) } }
                .accessibilityLabel("Folder path")
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await load(directory) } }
                .labelStyle(.iconOnly)
            Toggle("Hidden Files", isOn: $showHidden).toggleStyle(.checkbox)
            Button("Upload…", systemImage: "square.and.arrow.up") { chooseUpload() }
                .disabled(directory.isEmpty || transferring)
        }
        .disabled(isLoading || transferring)
        .padding(14)
        .help(server.name)
    }

    private func fileRow(_ entry: RemoteFileEntry, server: Server) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(entry))
                .foregroundStyle(entry.kind == .directory ? Color.accentColor : .secondary)
                .frame(width: 24)
            Text(entry.name).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.kind == .directory ? "—" : entry.size.byteString)
                .foregroundStyle(.secondary).monospacedDigit().frame(width: 100, alignment: .trailing)
            if let modified = entry.modifiedAt {
                Text(modified, format: .dateTime.month().day().hour().minute())
                    .foregroundStyle(.secondary).frame(width: 150, alignment: .trailing)
            }
            if entry.kind == .directory || entry.kind == .symbolicLink {
                Button("Open Folder", systemImage: "chevron.right") { Task { await load(entry.path) } }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            } else if entry.kind == .file {
                Button("Download", systemImage: "arrow.down.circle") { chooseDownload(entry, server: server) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if entry.kind == .directory || entry.kind == .symbolicLink { Task { await load(entry.path) } }
            else if entry.kind == .file { chooseDownload(entry, server: server) }
        }
        .contextMenu {
            if entry.kind == .directory || entry.kind == .symbolicLink {
                Button("Open Folder") { Task { await load(entry.path) } }
            } else if entry.kind == .file {
                Button("Download…") { chooseDownload(entry, server: server) }
            }
        }
        .disabled(transferring)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if transferring { ProgressView().controlSize(.small) }
            Text(status ?? String(format: NSLocalizedString("%d items · Drag files here to upload", comment: "Files footer"), visibleEntries.count))
                .foregroundStyle(.secondary)
            Spacer()
            if transferring { Button("Cancel") { transferTask?.cancel() } }
        }
        .font(.callout)
        .padding(14)
    }

    @MainActor private func load(_ path: String) async {
        guard let server = state.selectedServer else { return }
        let request = UUID()
        requestID = request
        isLoading = true
        defer { if requestID == request { isLoading = false } }
        do {
            let listing = try await SSHFileService(ssh: state.ssh).list(path: path, on: server)
            guard !Task.isCancelled, requestID == request, isCurrent(server) else { return }
            directory = listing.path
            location = listing.path
            entries = listing.entries
            issue = nil
        } catch {
            guard !OperationCancellation.isCancellation(error), !Task.isCancelled,
                  requestID == request, isCurrent(server) else { return }
            issue = error.localizedDescription
            location = directory
        }
    }

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Upload files", comment: "Files picker")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.begin { response in
            if response == .OK { startUpload(panel.urls) }
        }
    }

    private func startUpload(_ urls: [URL]) {
        guard let server = state.selectedServer, !directory.isEmpty, !transferring, !urls.isEmpty else { return }
        let destination = directory
        let transfer = UUID()
        transferID = transfer
        transferring = true
        issue = nil
        transferTask = Task { @MainActor in
            defer { if transferID == transfer { transferring = false } }
            var completed = 0
            do {
                for url in urls {
                    try Task.checkCancellation()
                    status = String(format: NSLocalizedString("Uploading %d of %d: %@", comment: "File upload status"), completed + 1, urls.count, url.lastPathComponent)
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try await SSHFileService(ssh: state.ssh).upload(url, to: destination, on: server)
                    completed += 1
                }
                guard transferID == transfer, isCurrent(server) else { return }
                status = String(format: NSLocalizedString("Uploaded %d files", comment: "File upload result"), completed)
                await load(destination)
            } catch {
                guard transferID == transfer, isCurrent(server) else { return }
                status = String(format: NSLocalizedString("Uploaded %d files", comment: "File upload result"), completed)
                await load(destination)
                if transferID == transfer, isCurrent(server), !OperationCancellation.isCancellation(error), !Task.isCancelled {
                    issue = error.localizedDescription
                }
            }
        }
    }

    private func chooseDownload(_ entry: RemoteFileEntry, server: Server) {
        guard !transferring else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard isCurrent(server) else { return }
            let overwrite = FileManager.default.fileExists(atPath: url.path)
            let transfer = UUID()
            transferID = transfer
            transferring = true
            status = String(format: NSLocalizedString("Downloading %@", comment: "File download status"), entry.name)
            transferTask = Task { @MainActor in
                defer { if transferID == transfer { transferring = false } }
                do {
                    try await SSHFileService(ssh: state.ssh).download(entry, to: url, on: server, overwrite: overwrite)
                    guard transferID == transfer, isCurrent(server) else { return }
                    status = NSLocalizedString("Download complete", comment: "File download result")
                } catch {
                    guard transferID == transfer, isCurrent(server) else { return }
                    if !OperationCancellation.isCancellation(error), !Task.isCancelled { issue = error.localizedDescription }
                    status = nil
                }
            }
        }
    }

    private func symbol(_ entry: RemoteFileEntry) -> String {
        switch entry.kind {
        case .directory: "folder.fill"
        case .symbolicLink: "link"
        case .file: "doc"
        case .other: "questionmark.square"
        }
    }
}
