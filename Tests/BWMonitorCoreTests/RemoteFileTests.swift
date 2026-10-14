import Foundation
import Testing
@testable import BWMonitorCore

@Suite("Remote files")
struct RemoteFileTests {
    @Test("NUL listing preserves arbitrary names and sorts folders first")
    func listing() throws {
        let odd = "a 'quote'\tline\n.txt"
        let result = try RemoteFileCommands.parseListing("/root\0f\0" + "123\0" + "1700000000.25\0" + odd + "\0d\0" + "4096\0" + "1700000000\0folder\0")
        #expect(result.entries.count == 2)
        #expect(result.entries[0].kind == .directory)
        #expect(result.entries[1].name == odd)
        #expect(result.entries[1].path == "/root/" + odd)
        #expect(result.entries[1].size == 123)
        #expect(try RemoteFileCommands.parseListing("/\0").entries.isEmpty)
    }

    @Test("Paths reject traversal components and preserve shell quoting")
    func safePaths() throws {
        #expect(try RemoteFileCommands.join(directory: "/", name: "a") == "/a")
        #expect(try RemoteFileCommands.join(directory: "/root/", name: "a") == "/root/a")
        #expect(throws: RemoteFileError.self) { try RemoteFileCommands.join(directory: "/root", name: "../a") }
        #expect(throws: RemoteFileError.self) { try RemoteFileCommands.list(path: "a\0b") }
        #expect(RemoteFileCommands.quote("x'; touch bad; '") == "'x'\\''; touch bad; '\\'''" )
        #expect(throws: RemoteFileError.self) { try RemoteFileCommands.parseListing("/root\0f\0x\0time\0name\0") }
    }

    @Test("SFTP options retain identity verification without shell options")
    func options() {
        let options = SSHFileService.scpOptions(from: ["-o", "StrictHostKeyChecking=yes", "-p", "2222", "-l", "root", "-i", "/keys/private", "-T", "--", "example.com"])
        #expect(options == ["-o", "StrictHostKeyChecking=yes", "-P", "2222", "-i", "/keys/private"])
        #expect(SSHFileService.escapeRemoteGlob("/tmp/a*[b]?\\c") == "/tmp/a\\*\\[b\\]\\?\\\\c")
    }

    @Test("Cloud token stays bound to provider during configuration replacement")
    func providerTokenBinding() throws {
        let store = KeychainStore(service: "com.mujh.ServerDock.token-test." + UUID().uuidString)
        let id = UUID()
        defer { try? store.deleteSecrets(for: id) }
        try store.saveCloudToken("vultr-test-token", for: id, provider: .vultr)
        #expect(try store.readCloudToken(for: id, provider: .vultr) == "vultr-test-token")
        #expect(try store.readCloudToken(for: id, provider: .hetznerCloud) == nil)
        try store.saveCloudToken("hetzner-test-token", for: id, provider: .hetznerCloud)
        #expect(try store.readCloudToken(for: id, provider: .vultr) == nil)
        #expect(try store.readCloudToken(for: id, provider: .hetznerCloud) == "hetzner-test-token")
    }
}
