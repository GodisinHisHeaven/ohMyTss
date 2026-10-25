// Synthetic HTTP behavior harness. Compiles the actual production StravaAPI.
// Does not import or emulate HealthKit, SwiftData, or SwiftUI.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main
struct VerifyStravaHTTP {
    @MainActor
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyntheticHTTP.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let missing = try await StravaAPI.getActivity(accessToken: "synthetic-test-token", activityID: 404, session: session)
        precondition(missing == nil, "Only 404 may become source unavailable")
        let present = try await StravaAPI.getActivity(accessToken: "synthetic-test-token", activityID: 200, session: session)
        precondition(present?.id == 200, "Successful source must decode its own ID")
        for id in [401, 403, 429, 500, 599, 201, 202] {
            var threw = false
            do { _ = try await StravaAPI.getActivity(accessToken: "synthetic-test-token", activityID: id, session: session) }
            catch { threw = true }
            precondition(threw, "Permission, offline, invalid JSON or mismatched IDs must never become deletion")
        }
        print("PASS: production Strava detail API; 9 synthetic HTTP/offline/decoding cases")
    }
}

private final class SyntheticHTTP: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "www.strava.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let id = Int(url.lastPathComponent) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        if id == 599 { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let status = [201, 202].contains(id) ? 200 : id
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body: String
        switch id {
        case 200: body = #"{"id":200,"start_date":"2023-11-14T22:13:20Z","moving_time":60,"sport_type":"Run"}"#
        case 201: body = "invalid synthetic JSON"
        case 202: body = #"{"id":999,"start_date":"2023-11-14T22:13:20Z"}"#
        default: body = #"{"message":"synthetic response"}"#
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
