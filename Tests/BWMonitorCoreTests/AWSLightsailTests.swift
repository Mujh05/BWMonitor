import Foundation
import Testing

@testable import BWMonitorCore

@Suite("AWS Lightsail traffic")
struct AWSLightsailTests {
    @Test("Billing month is always bounded in UTC")
    func utcMonthBounds() throws {
        let formatter = ISO8601DateFormatter()
        let date = try #require(formatter.date(from: "2026-10-31T23:59:59+08:00"))
        let bounds = AWSBillingMonth.bounds(containing: date)
        #expect(formatter.string(from: bounds.start) == "2026-10-01T00:00:00Z")
        #expect(formatter.string(from: bounds.end) == "2026-11-01T00:00:00Z")
    }

    @Test("Traffic totals and unknown quota remain honest")
    func totals() {
        let traffic = AWSMonthlyTraffic(
            inbound: 120, outbound: 80, limit: nil, quotaSource: .unknown,
            periodStart: .distantPast, nextReset: .distantFuture, latestDataPoint: .now
        )
        #expect(traffic.used == 200)
        #expect(traffic.remaining == nil)
        #expect(traffic.usagePercentage == nil)
    }

    @Test("SigV4 signs the required headers without leaking the secret")
    func signer() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2015-08-30T12:36:00Z"))
        var request = URLRequest(url: URL(string: "https://lightsail.ap-southeast-1.amazonaws.com/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("Lightsail_20161128.GetInstance", forHTTPHeaderField: "X-Amz-Target")
        let payload = Data(#"{"instanceName":"Singapore"}"#.utf8)
        AWSSigV4.sign(
            request: &request, payload: payload, service: "lightsail", region: "ap-southeast-1",
            credentials: AWSCredentials(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "SECRET", sessionToken: "TOKEN"),
            date: date
        )
        let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(request.value(forHTTPHeaderField: "X-Amz-Date") == "20150830T123600Z")
        #expect(request.value(forHTTPHeaderField: "X-Amz-Security-Token") == "TOKEN")
        #expect(authorization.contains("Credential=AKIDEXAMPLE/20150830/ap-southeast-1/lightsail/aws4_request"))
        #expect(authorization.contains("SECRET") == false)
    }

    @Test("Old server JSON keeps decoding without AWS fields")
    func legacyServerDecode() throws {
        let data = #"{"name":"CCM","host":"example.com","provider":"Generic Linux"}"#.data(using: .utf8)!
        let server = try JSONDecoder().decode(Server.self, from: data)
        #expect(server.awsInstanceName.isEmpty)
        #expect(server.awsRegion.isEmpty)
        #expect(server.awsMonthlyTransferOverrideGB == nil)
    }
}
