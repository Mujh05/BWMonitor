import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CloudProviderError: LocalizedError, Equatable {
    case invalidConfiguration
    case unsupportedProvider
    case invalidResponse
    case countersUnavailable
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            NSLocalizedString("Enter a valid instance ID and API token to read provider traffic.", comment: "Cloud API error")
        case .unsupportedProvider:
            NSLocalizedString("This provider supports SSH monitoring and files. Monthly billing traffic is not connected.", comment: "Cloud API capability")
        case .invalidResponse:
            NSLocalizedString("The provider returned an unreadable traffic response.", comment: "Cloud API error")
        case .countersUnavailable:
            NSLocalizedString("The provider has not published traffic counters yet. Try refreshing later.", comment: "Cloud API error")
        case let .http(status):
            String(format: NSLocalizedString("Provider API returned HTTP %d. Check the token, instance ID, and read permissions.", comment: "Cloud API error"), status)
        }
    }
}

public struct CloudProviderClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func fetchTraffic(server: Server, apiToken: String, now: Date = .now) async throws -> CloudProviderTraffic {
        guard server.provider.supportsCloudTraffic else { throw CloudProviderError.unsupportedProvider }
        let id = server.cloudInstanceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidInstanceID(id, provider: server.provider), !token.isEmpty,
              !token.contains("\r"), !token.contains("\n") else { throw CloudProviderError.invalidConfiguration }
        try Task.checkCancellation()
        switch server.provider {
        case .vultr: return try await vultr(id: id, token: token, overrideGB: server.cloudMonthlyTransferOverrideGB, now: now)
        case .hetznerCloud: return try await hetzner(id: id, token: token, overrideGB: server.cloudMonthlyTransferOverrideGB, now: now)
        default: throw CloudProviderError.unsupportedProvider
        }
    }

    public static func isValidInstanceID(_ id: String, provider: ServerProvider) -> Bool {
        switch provider {
        case .vultr: UUID(uuidString: id) != nil
        case .hetznerCloud: !id.isEmpty && id.utf8.allSatisfy { (48...57).contains($0) } && UInt64(id).map { $0 > 0 } == true
        default: false
        }
    }

    private func get<T: Decodable>(_ type: T.Type, url: URL, token: String) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw CloudProviderError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw CloudProviderError.http(http.statusCode) }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw CloudProviderError.invalidResponse }
    }

    private func vultr(id: String, token: String, overrideGB: Double?, now: Date) async throws -> CloudProviderTraffic {
        // https://www.vultr.com/api/#tag/instances/operation/get-instance-bandwidth
        // 32 UTC days includes the entire current month, including 31-day months.
        let base = URL(string: "https://api.vultr.com/v2/instances")!.appendingPathComponent(id)
        async let instance = get(VultrInstanceResponse.self, url: base, token: token)
        var components = URLComponents(url: base.appendingPathComponent("bandwidth"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "date_range", value: "32")]
        let response = try await get(VultrBandwidthResponse.self, url: components.url!, token: token)
        let info = try await instance.instance
        let bounds = Self.monthBounds(containing: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        var incoming: UInt64 = 0
        var outgoing: UInt64 = 0
        var latest: Date?
        for (day, point) in response.bandwidth {
            guard let date = formatter.date(from: day), date >= bounds.start, date < bounds.end, date <= now else { continue }
            let nextIn = incoming.addingReportingOverflow(point.incomingBytes)
            let nextOut = outgoing.addingReportingOverflow(point.outgoingBytes)
            guard !nextIn.overflow, !nextOut.overflow else { throw CloudProviderError.invalidResponse }
            incoming = nextIn.partialValue
            outgoing = nextOut.partialValue
            latest = max(latest ?? date, date)
        }
        guard latest != nil else { throw CloudProviderError.countersUnavailable }
        let override = Self.bytes(gb: overrideGB)
        let limit = override ?? Self.bytes(gb: info.allowedBandwidth)
        return CloudProviderTraffic(inbound: incoming, outbound: outgoing, limit: limit,
                                    quotaSource: override != nil ? "override" : (limit == nil ? "unknown" : "instance_plan"),
                                    periodStart: bounds.start, nextReset: bounds.end, latestDataPoint: latest,
                                    lastUpdated: now, serverOnline: info.powerStatus.map { $0 == "running" })
    }

    private func hetzner(id: String, token: String, overrideGB: Double?, now: Date) async throws -> CloudProviderTraffic {
        // https://docs.hetzner.cloud/reference/cloud#servers-get-a-server
        // null counters mean unavailable, never zero. Included traffic is bytes.
        let url = URL(string: "https://api.hetzner.cloud/v1/servers")!.appendingPathComponent(id)
        let info = try await get(HetznerResponse.self, url: url, token: token).server
        guard let outgoing = info.outgoingTraffic else { throw CloudProviderError.countersUnavailable }
        let bounds = Self.monthBounds(containing: now)
        let override = Self.bytes(gb: overrideGB)
        let limit = override ?? info.includedTraffic
        return CloudProviderTraffic(inbound: info.ingoingTraffic, outbound: outgoing, limit: limit,
                                    quotaSource: override != nil ? "override" : (limit == nil ? "unknown" : "provider"),
                                    periodStart: bounds.start, nextReset: bounds.end,
                                    lastUpdated: now, serverOnline: info.status.map { $0 == "running" })
    }

    private static func bytes(gb: Double?) -> UInt64? {
        guard let gb, gb.isFinite, gb > 0, gb * 1_000_000_000 < Double(UInt64.max) else { return nil }
        return UInt64((gb * 1_000_000_000).rounded(.down))
    }

    private static func monthBounds(containing date: Date) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
        return (start, calendar.date(byAdding: .month, value: 1, to: start)!)
    }
}

private struct VultrInstanceResponse: Decodable {
    let instance: Instance
    struct Instance: Decodable {
        let allowedBandwidth: Double?
        let powerStatus: String?
        enum CodingKeys: String, CodingKey { case allowedBandwidth = "allowed_bandwidth", powerStatus = "power_status" }
    }
}

private struct VultrBandwidthResponse: Decodable {
    let bandwidth: [String: Point]
    struct Point: Decodable {
        let incomingBytes: UInt64
        let outgoingBytes: UInt64
        enum CodingKeys: String, CodingKey { case incomingBytes = "incoming_bytes", outgoingBytes = "outgoing_bytes" }
    }
}

private struct HetznerResponse: Decodable {
    let server: ServerInfo
    struct ServerInfo: Decodable {
        let includedTraffic: UInt64?
        let ingoingTraffic: UInt64?
        let outgoingTraffic: UInt64?
        let status: String?
        enum CodingKeys: String, CodingKey {
            case includedTraffic = "included_traffic", ingoingTraffic = "ingoing_traffic", outgoingTraffic = "outgoing_traffic", status
        }
    }
}
