import Foundation

/// Intercepts URLSession traffic so API tests run against canned responses
/// instead of the network.
final class StubURLProtocol: URLProtocol {
    struct Stub {
        var statusCode: Int = 200
        var body: Data
    }

    /// Matched against the request URL's absolute string by substring.
    nonisolated(unsafe) static var stubs: [(match: String, stub: Stub)] = []
    nonisolated(unsafe) static var recordedRequests: [URLRequest] = []

    static func reset() {
        stubs = []
        recordedRequests = []
    }

    static func stub(matching fragment: String, json: String, statusCode: Int = 200) {
        stubs.append((fragment, Stub(statusCode: statusCode, body: Data(json.utf8))))
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recordedRequests.append(request)

        let url = request.url?.absoluteString ?? ""
        guard let match = Self.stubs.first(where: { url.contains($0.match) }) else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "StubURLProtocol", code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "No stub matching \(url)"]
                )
            )
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: match.stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: match.stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
