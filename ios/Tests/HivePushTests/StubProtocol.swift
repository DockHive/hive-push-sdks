import Foundation

/// A recorded request with its body read out of the stream.
struct RecordedRequest {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data

    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    var path: String { url.path }

    func query(_ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

/// A canned answer. `chunks` are delivered one after another (for streams).
struct StubResponse {
    var status: Int
    var headers: [String: String] = ["Content-Type": "application/json"]
    var chunks: [Data]

    static func json(_ status: Int, _ body: String = "") -> StubResponse {
        StubResponse(status: status, chunks: body.isEmpty ? [] : [Data(body.utf8)])
    }

    static func noContent() -> StubResponse { StubResponse(status: 204, chunks: []) }
}

/// URLProtocol stub: answers requests from a handler and records them.
final class StubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: ((RecordedRequest) -> StubResponse)?
    nonisolated(unsafe) private static var _requests: [RecordedRequest] = []

    static func reset(_ handler: @escaping (RecordedRequest) -> StubResponse) {
        lock.lock(); defer { lock.unlock() }
        _handler = handler
        _requests = []
    }

    static var requests: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        let rec = RecordedRequest(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: body
        )
        let handler: ((RecordedRequest) -> StubResponse)? = StubProtocol.lock.stubLocked {
            StubProtocol._requests.append(rec)
            return StubProtocol._handler
        }
        let resp = handler?(rec) ?? .json(500, #"{"code":"internal","error":"no stub"}"#)
        let http = HTTPURLResponse(url: request.url!, statusCode: resp.status, httpVersion: "HTTP/1.1", headerFields: resp.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        for c in resp.chunks {
            client?.urlProtocol(self, didLoad: c)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension NSLock {
    func stubLocked<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
