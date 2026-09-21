import Foundation
import Testing

@testable import BWMonitorCore

@Suite("SSH key files")
final class SSHKeyTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bwm-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func keygen(_ arguments: [String]) async throws {
        let output = try await ProcessRunner.run("/usr/bin/ssh-keygen", arguments: arguments, timeout: 30)
        #expect(output.status == 0, "\(output.stderr)")
    }

    private func fingerprint(of path: String) async throws -> String {
        let output = try await ProcessRunner.run("/usr/bin/ssh-keygen", arguments: ["-lf", path], timeout: 30)
        return output.stdout.split(separator: " ")[1].description
    }

    @Test("Generated keys match ssh-keygen")
    func generatedKey() async throws {
        let store = SSHKeyStore(directory: directory.appendingPathComponent("Keys"))
        let info = try await store.generateAppKey()
        #expect(info.algorithm == "ssh-ed25519")
        #expect(!info.isEncrypted)
        #expect(!SSHKeyInspector.hasLoosePermissions(path: info.path))
        #expect(info.fingerprint == (try await fingerprint(of: info.path)))
        let publicFile = try String(contentsOfFile: info.path + ".pub", encoding: .utf8)
        #expect(info.publicKey == publicFile.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(info.comment.hasPrefix("BWMonitor"))

        await #expect(throws: SSHKeyError.alreadyExists(store.appKeyPath)) {
            _ = try await store.generateAppKey()
        }
    }

    @Test("Encrypted keys are detected without the passphrase")
    func encryptedKey() async throws {
        let path = directory.appendingPathComponent("encrypted").path
        try await keygen(["-q", "-t", "ed25519", "-N", "correct horse", "-C", "enc", "-f", path])
        // Remove the .pub file: the public key must come from the private key file.
        try FileManager.default.removeItem(atPath: path + ".pub")
        let info = try SSHKeyInspector.inspect(path: path)
        #expect(info.isEncrypted)
        #expect(info.algorithm == "ssh-ed25519")
        #expect(info.publicKey?.hasPrefix("ssh-ed25519 AAAA") == true)
        #expect(info.fingerprint == (try await fingerprint(of: path)))
    }

    @Test("Legacy PEM keys use the .pub file")
    func pemKey() async throws {
        let path = directory.appendingPathComponent("legacy_rsa").path
        try await keygen(["-q", "-t", "rsa", "-b", "2048", "-m", "PEM", "-N", "", "-f", path])
        let info = try SSHKeyInspector.inspect(path: path)
        #expect(info.algorithm == "ssh-rsa")
        #expect(!info.isEncrypted)
        #expect(info.fingerprint == (try await fingerprint(of: path)))
    }

    @Test("Wrong files are explained")
    func wrongFiles() async throws {
        let path = directory.appendingPathComponent("id_test").path
        try await keygen(["-q", "-t", "ed25519", "-N", "", "-f", path])
        #expect(throws: SSHKeyError.publicKeyFile) { try SSHKeyInspector.inspect(path: path + ".pub") }

        let putty = directory.appendingPathComponent("key.ppk")
        try "PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\n".write(to: putty, atomically: true, encoding: .utf8)
        #expect(throws: SSHKeyError.puttyFormat) { try SSHKeyInspector.inspect(path: putty.path) }

        #expect(throws: SSHKeyError.notFound("/nonexistent/key")) { try SSHKeyInspector.inspect(path: "/nonexistent/key") }
    }

    @Test("Keys in ~/.ssh are discovered, default names first")
    func discovery() async throws {
        let ssh = directory.appendingPathComponent("ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try await keygen(["-q", "-t", "ed25519", "-N", "", "-f", ssh.appendingPathComponent("work").path])
        try await keygen(["-q", "-t", "ed25519", "-N", "", "-f", ssh.appendingPathComponent("id_ed25519").path])
        try "Host *\n".write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "".write(to: ssh.appendingPathComponent("known_hosts"), atomically: true, encoding: .utf8)
        let names = SSHKeyInspector.discoverKeys(in: ssh).map { URL(fileURLWithPath: $0.path).lastPathComponent }
        #expect(names == ["id_ed25519", "work"])
    }

    @Test("Pasted keys are stored privately")
    func importPasted() async throws {
        let source = directory.appendingPathComponent("source").path
        try await keygen(["-q", "-t", "ed25519", "-N", "", "-f", source])
        let text = try String(contentsOfFile: source, encoding: .utf8).replacingOccurrences(of: "\n", with: "\r\n")
        let store = SSHKeyStore(directory: directory.appendingPathComponent("Keys"))
        let info = try store.importPrivateKey(text)
        #expect(info.path.hasPrefix(store.directory.path))
        #expect(!SSHKeyInspector.hasLoosePermissions(path: info.path))
        #expect(info.fingerprint == (try await fingerprint(of: source)))
        #expect(throws: SSHKeyError.notAPrivateKey) { try store.importPrivateKey("hello") }
    }
}

@Suite("Server settings")
struct ServerModelTests {
    @Test("servers.json from 1.0 still loads")
    func legacyJSON() throws {
        let json = """
        [{"authentication":"Private Key / SSH Agent","createdAt":"2026-09-21T08:35:41Z","host":"203.0.113.10",
          "id":"27937D8C-D921-414F-B0CD-01E142018FE9","name":"VPS","operatingSystem":"Linux","port":22,
          "privateKeyPath":"/Users/me/.ssh/id_ed25519","provider":"BandwagonHost","username":"root","veid":"1000000"}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let servers = try decoder.decode([Server].self, from: Data(json.utf8))
        #expect(servers.first?.authentication == .key)
        #expect(servers.first?.provider == .bandwagonHost)
        #expect(servers.first?.privateKeyPath == "/Users/me/.ssh/id_ed25519")
    }

    @Test("Missing fields get defaults")
    func missingFields() throws {
        let server = try JSONDecoder().decode(Server.self, from: Data(#"{"name":"A","host":"example.com"}"#.utf8))
        #expect(server.port == 22)
        #expect(server.username == "root")
        #expect(server.authentication == .key)
    }

    @Test("Typed fields are trimmed and checked")
    func normalization() {
        let server = Server(name: " VPS ", host: " 203.0.113.10\n", username: "root ").normalized
        #expect(server.host == "203.0.113.10")
        #expect(server.username == "root")
        #expect(Server.isValidHost("[2001:db8::1]"))
        #expect(!Server.isValidHost("host name"))
        #expect(!Server.isValidHost("-oProxyCommand=x"))
        #expect(!Server.isValidUsername("-l"))
    }
}

@Suite("KiwiVM", .serialized)
struct KiwiVMTests {
    @Test("Traffic uses the data multiplier; power state is optional")
    func decoding() async throws {
        let json = #"{"error":0,"data_counter":"1000","plan_monthly_data":4000,"data_next_reset":1790000000,"monthly_data_multiplier":1.5,"suspended":false}"#
        let traffic = try await KiwiVMClient(session: StubURLProtocol.session(json: json)).serviceInfo(veid: "1", apiKey: "k")
        #expect(traffic.used == 1_500)
        #expect(traffic.limit == 6_000)
        #expect(traffic.serverOnline == nil)
    }

    @Test("API errors are reported")
    func apiError() async throws {
        let session = StubURLProtocol.session(json: #"{"error":700005,"message":"Authentication failure"}"#)
        await #expect(throws: KiwiVMError.api("Authentication failure")) {
            _ = try await KiwiVMClient(session: session).serviceInfo(veid: "1", apiKey: "k")
        }
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()

    static func session(json: String) -> URLSession {
        body = Data(json.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
