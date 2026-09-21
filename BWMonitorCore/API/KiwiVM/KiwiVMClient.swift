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
        return BandwagonTraffic(
            used: used,
            limit: limit,
            nextReset: Date(timeIntervalSince1970: TimeInterval(reset)),
            serverOnline: payload.status?.lowercased() == "online"
                || payload.vmStatus?.lowercased() == "running"
        )
    }
}

private extension KiwiVMClient {
    struct Response: Decodable {
        let error: Int
        let message: String?
        let dataCounter: UInt64?
        let planMonthlyData: UInt64?
        let dataNextReset: UInt64?
        let status: String?
        let vmStatus: String?

        enum CodingKeys: String, CodingKey {
            case error
            case message
            case dataCounter = "data_counter"
            case planMonthlyData = "plan_monthly_data"
            case dataNextReset = "data_next_reset"
            case status = "ve_status"
            case vmStatus = "vm_status"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            error = container.decodeLossyInt(forKey: .error) ?? 0
            message = try? container.decode(String.self, forKey: .message)
            dataCounter = container.decodeLossyUInt64(forKey: .dataCounter)
            planMonthlyData = container.decodeLossyUInt64(forKey: .planMonthlyData)
            dataNextReset = container.decodeLossyUInt64(forKey: .dataNextReset)
            status = try? container.decode(String.self, forKey: .status)
            vmStatus = try? container.decode(String.self, forKey: .vmStatus)
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyUInt64(forKey key: Key) -> UInt64? {
        if let number = try? decode(UInt64.self, forKey: key) { return number }
        if let text = try? decode(String.self, forKey: key) { return UInt64(text) }
        return nil
    }

    func decodeLossyInt(forKey key: Key) -> Int? {
        if let number = try? decode(Int.self, forKey: key) { return number }
        if let text = try? decode(String.self, forKey: key) { return Int(text) }
        return nil
    }
}
