import Foundation

/// Sends requests to the Hive Push SDK endpoints (`/sdk/v1/...`).
final class Transport: @unchecked Sendable {
    let baseURL: URL
    let key: String
    let session: URLSession

    init(baseURL: URL, key: String, session: URLSession) {
        self.baseURL = baseURL
        self.key = key
        self.session = session
    }

    static let userAgent = "HivePush-iOS/\(HivePush.sdkVersion)"

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: baseURL.appendingPathComponent("sdk/v1/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            c.queryItems = query
            // "+" is literal in query strings; encode it so user tokens survive.
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return c.url!
    }

    func makeRequest(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) throws -> URLRequest {
        var req = URLRequest(url: url(path, query: query))
        req.httpMethod = method
        req.setValue(key, forHTTPHeaderField: "X-Hive-Push-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Transport.userAgent, forHTTPHeaderField: "User-Agent")
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        return req
    }

    /// Sends a request and returns the body of a 2xx answer; other answers
    /// throw `HivePushError` with the API's code.
    @discardableResult
    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> Data {
        let req: URLRequest
        do {
            req = try makeRequest(method, path, query: query, body: body)
        } catch {
            throw HivePushError(code: "invalid_options", message: "Could not encode the request: \(error)")
        }
        let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { cont in
            let task = session.dataTask(with: req) { data, response, error in
                if let error = error {
                    cont.resume(throwing: HivePushError(code: "network", message: "Network error talking to Hive Push: \(error.localizedDescription)"))
                } else if let response = response {
                    cont.resume(returning: (data ?? Data(), response))
                } else {
                    cont.resume(throwing: HivePushError(code: "network", message: "No response from Hive Push"))
                }
            }
            task.resume()
        }
        guard let http = response as? HTTPURLResponse else {
            throw HivePushError(code: "invalid_response", message: "Not an HTTP response")
        }
        if (200..<300).contains(http.statusCode) {
            return data
        }
        throw Transport.error(status: http.statusCode, body: data)
    }

    /// Maps an error answer (`{"error": "...", "code": "..."}`) to a `HivePushError`.
    static func error(status: Int, body: Data) -> HivePushError {
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let code = obj?["code"] as? String ?? "http_\(status)"
        let message = obj?["error"] as? String ?? "Hive Push request failed (HTTP \(status))"
        return HivePushError(code: code, message: message, status: status)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw HivePushError(code: "invalid_response", message: "Unexpected answer from Hive Push: \(error)")
        }
    }
}

/// Builds `https://push-<region>.dockhive.io`, or uses an explicit host.
func hivePushBaseURL(region: String? = nil, host: String? = nil) -> URL? {
    if let host = host?.trimmingCharacters(in: .whitespaces), !host.isEmpty {
        var h = host
        while h.hasSuffix("/") { h.removeLast() }
        if !h.lowercased().hasPrefix("http://") && !h.lowercased().hasPrefix("https://") {
            h = "https://" + h
        }
        return URL(string: h)
    }
    if let region = region?.trimmingCharacters(in: .whitespaces), !region.isEmpty {
        return URL(string: "https://push-\(region.lowercased()).dockhive.io")
    }
    return nil
}
