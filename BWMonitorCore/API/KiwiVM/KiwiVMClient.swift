import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum KiwiVMError: LocalizedError, Equatable {
    case invalidConfiguration
    case invalidResponse
    case api(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            NSLocalizedString("KiwiVM requires both a VEID and API key.", comment: "KiwiVM configuration error")
        case .invalidResponse:
            NSLocalizedString("KiwiVM returned an unreadable response.", comment: "KiwiVM response error")
        case let .api(message):
            String(format: NSLocalizedString("KiwiVM: %@", comment: "KiwiVM API error"), message)
        }
    }
}

public protocol KiwiVMServing: Sendable {
    func serviceInfo(veid: String, apiKey: String) async throws -> BandwagonTraffic
}

public struct KiwiVMClient: KiwiVMServing, Sendable {
    private let session: URLSession
    private let baseURL: URL

    public init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.64clouds.com/v1")!
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    public func serviceInfo(veid: String, apiKey: String) async throws -> BandwagonTraffic {
        guard !veid.isEmpty, !apiKey.isEmpty else { throw KiwiVMError.invalidConfiguration }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("getServiceInfo"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "veid", value: veid),
            URLQueryItem(name: "api_key", value: apiKey)
        ]
        guard let url = components?.url else { throw KiwiVMError.invalidConfiguration }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw KiwiVMError.invalidResponse
        }
        let payload = try JSONDecoder().decode(Response.self, from: data)
        if payload.error != 0 {
            throw KiwiVMError.api(
                payload.message ?? NSLocalizedString("Request failed", comment: "Generic request failure")
            )
        }
        guard let used = payload.dataCounter,
              let limit = payload.planMonthlyData,
              let reset = payload.dataNextReset else {
            throw KiwiVMError.invalidResponse
        }
        // KiwiVM documents that both counters must be multiplied by
        // monthly_data_multiplier; it is 1 for most locations.
        let multiplier = max(payload.monthlyDataMultiplier ?? 1, 0)
        return BandwagonTraffic(
            used: UInt64((Double(used) * multiplier).rounded()),
            limit: UInt64((Double(limit) * multiplier).rounded()),
            nextReset: Date(timeIntervalSince1970: TimeInterval(reset)),
            serverOnline: Self.powerState(payload)
        )
    }

    private static func powerState(_ payload: Response) -> Bool? {
        if payload.suspended == true { return false }
        for status in [payload.status, payload.vmStatus].compactMap({ $0?.lowercased() }) {
            if ["running", "online", "started"].contains(status) { return true }
            if ["stopped", "offline", "suspended"].contains(status) { return false }
        }
        return nil
    }
}

private extension KiwiVMClient {
    struct Response: Decodable {
        let error: Int
        let message: String?
        let dataCounter: UInt64?
        let planMonthlyData: UInt64?
        let dataNextReset: UInt64?
        let monthlyDataMultiplier: Double?
        let status: String?
        let vmStatus: String?
        let suspended: Bool?

        enum CodingKeys: String, CodingKey {
            case error
            case message
            case dataCounter = "data_counter"
            case planMonthlyData = "plan_monthly_data"
            case dataNextReset = "data_next_reset"
            case monthlyDataMultiplier = "monthly_data_multiplier"
            case status = "ve_status"
            case vmStatus = "vm_status"
            case suspended
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            error = container.decodeLossyInt(forKey: .error) ?? 0
            message = try? container.decode(String.self, forKey: .message)
            dataCounter = container.decodeLossyUInt64(forKey: .dataCounter)
            planMonthlyData = container.decodeLossyUInt64(forKey: .planMonthlyData)
            dataNextReset = container.decodeLossyUInt64(forKey: .dataNextReset)
            monthlyDataMultiplier = container.decodeLossyDouble(forKey: .monthlyDataMultiplier)
            status = try? container.decode(String.self, forKey: .status)
            vmStatus = try? container.decode(String.self, forKey: .vmStatus)
            suspended = (try? container.decode(Bool.self, forKey: .suspended))
                ?? container.decodeLossyInt(forKey: .suspended).map { $0 != 0 }
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyUInt64(forKey key: Key) -> UInt64? {
        if let number = try? decode(UInt64.self, forKey: key) { return number }
        if let text = try? decode(String.self, forKey: key) { return UInt64(text) }
        return nil
    }

    func decodeLossyDouble(forKey key: Key) -> Double? {
        if let number = try? decode(Double.self, forKey: key) { return number }
        if let text = try? decode(String.self, forKey: key) { return Double(text) }
        return nil
    }

    func decodeLossyInt(forKey key: Key) -> Int? {
        if let number = try? decode(Int.self, forKey: key) { return number }
        if let text = try? decode(String.self, forKey: key) { return Int(text) }
        return nil
    }
}
