import Foundation
import Testing
@testable import BWMonitorCore

@Suite("Cloud provider adapters", .serialized)
struct CloudProviderTests {
    private let instanceID = "11111111-1111-4111-8111-111111111111"
    private var now: Date { ISO8601DateFormatter().date(from: "2026-10-13T06:00:00Z")! }

    @Test("All new providers round-trip and old server files retain safe defaults")
    func providersAndLegacyDecode() throws {
        for provider in [ServerProvider.digitalOcean, .vultr, .hetznerCloud, .alibabaCloud, .tencentCloud, .oracleCloud] {
            let server = Server(name: "VPS", host: "example.com", provider: provider, cloudInstanceID: "123")
            let decoded = try JSONDecoder().decode(Server.self, from: JSONEncoder().encode(server))
            #expect(decoded == server)
            #expect(decoded.isValid)
        }
        let old = try JSONDecoder().decode(Server.self, from: Data(#"{"name":"Old VPS","host":"example.com","provider":"AWS Lightsail"}"#.utf8))
        #expect(old.cloudInstanceID.isEmpty)
        #expect(old.cloudMonthlyTransferOverrideGB == nil)
        #expect(!SecretKind.cloudAPIKey.isAskpassSecret)
        #expect(!ServerProvider.digitalOcean.supportsTrafficAPI)
        #expect(ServerProvider.vultr.supportsTrafficAPI)
    }

    @Test("Vultr totals include only current UTC month, bill outbound, and request 32 days")
    func vultrMonth() async throws {
        let session = CloudStubURLProtocol.session(responses: [
            "/v2/instances/\(instanceID)": #"{"instance":{"allowed_bandwidth":1000,"power_status":"running"}}"#,
            "/v2/instances/\(instanceID)/bandwidth": #"{"bandwidth":{"2026-09-30":{"incoming_bytes":999,"outgoing_bytes":999},"2026-10-01":{"incoming_bytes":100,"outgoing_bytes":200},"2026-10-13":{"incoming_bytes":300,"outgoing_bytes":400},"2026-10-14":{"incoming_bytes":999,"outgoing_bytes":999}}}"#
        ])
        let server = Server(name: "Vultr", host: "example.com", provider: .vultr, cloudInstanceID: instanceID)
        let traffic = try await CloudProviderClient(session: session).fetchTraffic(server: server, apiToken: "synthetic-token", now: now)
        #expect(traffic.inbound == 400)
        #expect(traffic.outbound == 600)
        #expect(traffic.used == 600)
        #expect(traffic.limit == 1_000_000_000_000)
        #expect(traffic.quotaSource == "instance_plan")
        #expect(traffic.serverOnline == true)
        let requests = CloudStubURLProtocol.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token" })
        #expect(requests.allSatisfy { $0.url?.query?.contains("synthetic-token") != true })
        let bandwidth = try #require(requests.first { $0.url?.path.hasSuffix("bandwidth") == true })
        #expect(URLComponents(url: bandwidth.url!, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "date_range", value: "32")])
    }

    @Test("Vultr missing current-month counters are not fabricated as zero")
    func vultrMissing() async throws {
        let session = CloudStubURLProtocol.session(responses: [
            "/v2/instances/\(instanceID)": #"{"instance":{"allowed_bandwidth":1000}}"#,
            "/v2/instances/\(instanceID)/bandwidth": #"{"bandwidth":{"2026-09-30":{"incoming_bytes":1,"outgoing_bytes":2}}}"#
        ])
        let server = Server(name: "Vultr", host: "example.com", provider: .vultr, cloudInstanceID: instanceID)
        await #expect(throws: CloudProviderError.countersUnavailable) {
            _ = try await CloudProviderClient(session: session).fetchTraffic(server: server, apiToken: "synthetic-token", now: now)
        }
    }

    @Test("Hetzner native byte units and outgoing-only allowance")
    func hetznerBytes() async throws {
        let session = CloudStubURLProtocol.session(responses: [
            "/v1/servers/123": #"{"server":{"included_traffic":20000000000000,"ingoing_traffic":12000000000,"outgoing_traffic":5000000000,"status":"running"}}"#
        ])
        let server = Server(name: "Hetzner", host: "example.com", provider: .hetznerCloud, cloudInstanceID: "123")
        let traffic = try await CloudProviderClient(session: session).fetchTraffic(server: server, apiToken: "synthetic-token", now: now)
        #expect(traffic.inbound == 12_000_000_000)
        #expect(traffic.used == 5_000_000_000)
        #expect(traffic.limit == 20_000_000_000_000)
        #expect(traffic.remaining == 19_995_000_000_000)
        #expect(traffic.quotaSource == "provider")
        #expect(traffic.latestDataPoint == nil)
        #expect(ISO8601DateFormatter().string(from: traffic.nextReset) == "2026-11-01T00:00:00Z")
    }

    @Test("Hetzner null inbound is preserved and null outbound reports unavailable")
    func hetznerNulls() async throws {
        let session = CloudStubURLProtocol.session(responses: [
            "/v1/servers/123": #"{"server":{"included_traffic":null,"ingoing_traffic":null,"outgoing_traffic":25}}"#
        ])
        let server = Server(name: "Hetzner", host: "example.com", provider: .hetznerCloud, cloudInstanceID: "123")
        let traffic = try await CloudProviderClient(session: session).fetchTraffic(server: server, apiToken: "synthetic-token", now: now)
        #expect(traffic.inbound == nil)
        #expect(traffic.limit == nil)
        #expect(traffic.usagePercentage == nil)
        let missing = CloudStubURLProtocol.session(responses: ["/v1/servers/123": #"{"server":{"outgoing_traffic":null}}"#])
        await #expect(throws: CloudProviderError.countersUnavailable) {
            _ = try await CloudProviderClient(session: missing).fetchTraffic(server: server, apiToken: "synthetic-token", now: now)
        }
    }

    @Test("Manual quota, widget counters, and provider alerts use outbound bytes")
    func overrideWidgetAlerts() async throws {
        let session = CloudStubURLProtocol.session(responses: ["/v1/servers/123": #"{"server":{"ingoing_traffic":9000000000,"outgoing_traffic":900000000,"included_traffic":20000000000000}}"#])
        let server = Server(name: "Hetzner", host: "example.com", provider: .hetznerCloud, cloudInstanceID: "123", cloudMonthlyTransferOverrideGB: 1)
        var traffic = try await CloudProviderClient(session: session).fetchTraffic(server: server, apiToken: "synthetic-token", now: now)
        #expect(traffic.limit == 1_000_000_000)
        #expect(traffic.usagePercentage == 0.9)
        #expect(traffic.quotaSource == "override")
        let snapshot = WidgetSnapshot(server: server, metrics: nil, traffic: nil, cloudTraffic: traffic)
        #expect(snapshot.trafficUsed == 900_000_000)
        #expect(snapshot.trafficLimit == 1_000_000_000)
        #expect(AlertEvaluator.evaluate(server: server, metrics: nil, traffic: nil, cloudTraffic: traffic, thresholds: .init()).count == 1)
        traffic.quotaSource = "instance_plan"
        #expect(AlertEvaluator.evaluate(server: server, metrics: nil, traffic: nil, cloudTraffic: traffic, thresholds: .init()).isEmpty)
    }

    @Test("HTTP failures, invalid IDs, and SSH-only providers fail explicitly")
    func failures() async throws {
        let session = CloudStubURLProtocol.session(responses: [:], status: 401)
        let client = CloudProviderClient(session: session)
        let server = Server(name: "Hetzner", host: "example.com", provider: .hetznerCloud, cloudInstanceID: "123")
        await #expect(throws: CloudProviderError.http(401)) { _ = try await client.fetchTraffic(server: server, apiToken: "synthetic-token") }
        #expect(!CloudProviderClient.isValidInstanceID("../account", provider: .hetznerCloud))
        #expect(!CloudProviderClient.isValidInstanceID("0", provider: .hetznerCloud))
        #expect(!CloudProviderClient.isValidInstanceID("../account", provider: .vultr))
        await #expect(throws: CloudProviderError.invalidConfiguration) { _ = try await client.fetchTraffic(server: server, apiToken: "token\ninjected") }
        let sshOnly = Server(name: "OCI", host: "example.com", provider: .oracleCloud)
        await #expect(throws: CloudProviderError.unsupportedProvider) { _ = try await client.fetchTraffic(server: sshOnly, apiToken: "synthetic-token") }
    }
}

private final class CloudStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: String] = [:]
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { captured } }

    static func session(responses: [String: String], status: Int = 200) -> URLSession {
        lock.withLock { Self.responses = responses; Self.status = status; captured = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (body, status) = Self.lock.withLock {
            Self.captured.append(request)
            return (Self.responses[request.url!.path] ?? "{}", Self.status)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
