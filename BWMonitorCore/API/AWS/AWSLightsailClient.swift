import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AWSCredentials: Sendable {
    public var accessKeyID: String
    public var secretAccessKey: String
    public var sessionToken: String?

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken?.isEmpty == true ? nil : sessionToken
    }
}

public enum AWSLightsailError: LocalizedError, Equatable {
    case invalidConfiguration
    case invalidResponse
    case service(code: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            NSLocalizedString("AWS Lightsail requires an instance name, region, access key ID, and secret access key.", comment: "AWS configuration error")
        case .invalidResponse:
            NSLocalizedString("AWS Lightsail returned an unreadable response.", comment: "AWS response error")
        case let .service(code, message):
            "AWS Lightsail (\(code)): \(message)"
        }
    }
}

public final class AWSLightsailClient: @unchecked Sendable {
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(session: URLSession = .shared, now: @escaping @Sendable () -> Date = { .now }) {
        self.session = session
        self.now = now
    }

    public func monthlyTraffic(
        instanceName: String,
        region: String,
        credentials: AWSCredentials,
        quotaOverrideGB: Double? = nil
    ) async throws -> AWSMonthlyTraffic {
        let instanceName = instanceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !instanceName.isEmpty, !region.isEmpty,
              !credentials.accessKeyID.isEmpty, !credentials.secretAccessKey.isEmpty else {
            throw AWSLightsailError.invalidConfiguration
        }

        let fetchedAt = now()
        let bounds = AWSBillingMonth.bounds(containing: fetchedAt)
        async let inbound = metric(
            name: "NetworkIn", instanceName: instanceName, region: region,
            start: bounds.start, end: fetchedAt, credentials: credentials
        )
        async let outbound = metric(
            name: "NetworkOut", instanceName: instanceName, region: region,
            start: bounds.start, end: fetchedAt, credentials: credentials
        )
        async let bundle = bundle(instanceName: instanceName, region: region, credentials: credentials)
        let (inPoints, outPoints, bundleInfo) = try await (inbound, outbound, bundle)

        var merged: [Date: AWSTrafficPoint] = [:]
        for point in inPoints {
            merged[point.timestamp, default: AWSTrafficPoint(timestamp: point.timestamp)].inbound = point.bytes
        }
        for point in outPoints {
            merged[point.timestamp, default: AWSTrafficPoint(timestamp: point.timestamp)].outbound = point.bytes
        }
        let points = merged.values.sorted { $0.timestamp < $1.timestamp }
        let inTotal = inPoints.reduce(UInt64(0)) { $0 &+ $1.bytes }
        let outTotal = outPoints.reduce(UInt64(0)) { $0 &+ $1.bytes }
        let override = quotaOverrideGB.flatMap { $0 > 0 ? Self.bytes(gigabytes: $0) : nil }
        let bundleLimit = bundleInfo.transferGB.flatMap(Self.bytes(gigabytes:))
        let limit = override ?? bundleLimit
        let source: AWSQuotaSource = override != nil ? .override : (bundleLimit != nil ? .bundle : .unknown)
        return AWSMonthlyTraffic(
            inbound: inTotal,
            outbound: outTotal,
            limit: limit,
            quotaSource: source,
            periodStart: bounds.start,
            nextReset: bounds.end,
            latestDataPoint: (inPoints + outPoints).map(\.timestamp).max(),
            lastUpdated: fetchedAt,
            points: points,
            bundleID: bundleInfo.id
        )
    }

    private struct MetricPoint: Sendable {
        var timestamp: Date
        var bytes: UInt64
    }

    private func metric(
        name: String,
        instanceName: String,
        region: String,
        start: Date,
        end: Date,
        credentials: AWSCredentials
    ) async throws -> [MetricPoint] {
        let body: [String: Any] = [
            "instanceName": instanceName,
            "metricName": name,
            "period": 300,
            "startTime": start.timeIntervalSince1970,
            "endTime": end.timeIntervalSince1970,
            "statistics": ["Sum"],
            "unit": "Bytes"
        ]
        let data = try await call(target: "GetInstanceMetricData", body: body, region: region, credentials: credentials)
        let response = try JSONDecoder().decode(MetricResponse.self, from: data)
        return response.metricData.compactMap { point in
            guard let sum = point.sum, sum.isFinite, sum >= 0 else { return nil }
            return MetricPoint(timestamp: Date(timeIntervalSince1970: point.timestamp), bytes: UInt64(sum.rounded()))
        }
    }

    private func bundle(
        instanceName: String,
        region: String,
        credentials: AWSCredentials
    ) async throws -> (id: String?, transferGB: Double?) {
        let instanceData = try await call(
            target: "GetInstance", body: ["instanceName": instanceName], region: region, credentials: credentials
        )
        let instance = try JSONDecoder().decode(InstanceResponse.self, from: instanceData).instance
        guard let bundleID = instance.bundleId, !bundleID.isEmpty else { return (nil, nil) }
        let bundleData = try await call(target: "GetBundles", body: [:], region: region, credentials: credentials)
        let bundles = try JSONDecoder().decode(BundlesResponse.self, from: bundleData).bundles
        return (bundleID, bundles.first(where: { $0.bundleId == bundleID })?.transferPerMonthInGb)
    }

    private func call(
        target: String,
        body: [String: Any],
        region: String,
        credentials: AWSCredentials
    ) async throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let endpoint = URL(string: "https://lightsail.\(region).amazonaws.com/")!
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("Lightsail_20161128.\(target)", forHTTPHeaderField: "X-Amz-Target")
        AWSSigV4.sign(
            request: &request, payload: payload, service: "lightsail", region: region,
            credentials: credentials, date: now()
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AWSLightsailError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let failure = (try? JSONDecoder().decode(ServiceFailure.self, from: data))
            let code = failure?.type?.split(separator: "#").last.map(String.init) ?? "HTTP\(http.statusCode)"
            let message = failure?.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw AWSLightsailError.service(code: code, message: message)
        }
        return data
    }

    private static func bytes(gigabytes: Double) -> UInt64? {
        let value = gigabytes * 1_000_000_000
        guard value.isFinite, value > 0, value <= Double(UInt64.max) else { return nil }
        return UInt64(value.rounded())
    }
}

enum AWSSigV4 {
    static func sign(
        request: inout URLRequest,
        payload: Data,
        service: String,
        region: String,
        credentials: AWSCredentials,
        date: Date
    ) {
        let dateStamp = format(date, "yyyyMMdd")
        let amzDate = format(date, "yyyyMMdd'T'HHmmss'Z'")
        let host = request.url!.host!
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let token = credentials.sessionToken {
            request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        let signedNames = ["content-type", "host", "x-amz-date"]
            + (credentials.sessionToken == nil ? [] : ["x-amz-security-token"])
            + ["x-amz-target"]
        let canonicalHeaders = signedNames.map { name in
            let value = request.value(forHTTPHeaderField: name)!
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return "\(name):\(value)\n"
        }.joined()
        let signedHeaders = signedNames.joined(separator: ";")
        let payloadHash = SHA256.hash(data: payload).hex
        let canonicalRequest = [
            request.httpMethod ?? "POST", request.url?.path.isEmpty == false ? request.url!.path : "/", "",
            canonicalHeaders, signedHeaders, payloadHash
        ].joined(separator: "\n")
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, SHA256.hash(data: Data(canonicalRequest.utf8)).hex]
            .joined(separator: "\n")
        let dateKey = hmac(Data(("AWS4" + credentials.secretAccessKey).utf8), Data(dateStamp.utf8))
        let regionKey = hmac(dateKey, Data(region.utf8))
        let serviceKey = hmac(regionKey, Data(service.utf8))
        let signingKey = hmac(serviceKey, Data("aws4_request".utf8))
        let signature = hmac(signingKey, Data(stringToSign.utf8)).map { String(format: "%02x", $0) }.joined()
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    private static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func format(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

private extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

private struct MetricResponse: Decodable {
    struct Point: Decodable { let timestamp: Double; let sum: Double? }
    let metricData: [Point]
}

private struct InstanceResponse: Decodable {
    struct Instance: Decodable { let bundleId: String? }
    let instance: Instance
}

private struct BundlesResponse: Decodable {
    struct Bundle: Decodable { let bundleId: String; let transferPerMonthInGb: Double? }
    let bundles: [Bundle]
}

private struct ServiceFailure: Decodable {
    let type: String?
    let message: String?

    enum CodingKeys: String, CodingKey { case type = "__type"; case message }
}
