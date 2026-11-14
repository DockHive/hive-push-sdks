import Foundation

/// Parses a Server-Sent Events byte stream into events.
struct SSEParser {
    struct Event: Equatable {
        var id: String?
        var event: String
        var data: String
    }

    private var buffer = Data()
    private var eventName = ""
    private var dataLines: [String] = []
    private var lastId: String?

    /// Feeds bytes and returns the events completed by them.
    mutating func feed(_ chunk: Data) -> [Event] {
        buffer.append(chunk)
        var out: [Event] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<nl]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            buffer.removeSubrange(buffer.startIndex...nl)
            let line = String(decoding: lineData, as: UTF8.self)
            if let ev = handle(line) { out.append(ev) }
        }
        return out
    }

    private mutating func handle(_ line: String) -> Event? {
        if line.isEmpty {
            defer { eventName = ""; dataLines = [] }
            guard !dataLines.isEmpty else { return nil }
            return Event(id: lastId, event: eventName.isEmpty ? "message" : eventName, data: dataLines.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil } // comment (": ping")
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[line.startIndex..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        case "id": lastId = String(value)
        default: break // "retry" and unknown fields
        }
        return nil
    }
}

/// One live inbox connection (`GET /sdk/v1/stream`) that reconnects with backoff.
/// Works on iOS 14 (a delegate-based `URLSession` data task, not `bytes(for:)`).
final class EventStreamConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let transport: Transport
    private let tokenProvider: () -> String?
    private let initialDelay: TimeInterval
    private let maxDelay: TimeInterval
    private let queue = DispatchQueue(label: "io.dockhive.push.stream")
    private let delegateQueue: OperationQueue

    var onItem: ((InboxItem) -> Void)?
    var onFatal: ((HivePushError) -> Void)?

    // State, only touched on `queue`.
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var parser = SSEParser()
    private var status = 0
    private var errorBody = Data()
    private var delay: TimeInterval
    private var stopped = false
    private var retryAfter: TimeInterval?

    init(transport: Transport, tokenProvider: @escaping () -> String?, initialDelay: TimeInterval, maxDelay: TimeInterval) {
        self.transport = transport
        self.tokenProvider = tokenProvider
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.delay = initialDelay
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.underlyingQueue = queue
        self.delegateQueue = q
        super.init()
    }

    func start() {
        queue.async { self.connect() }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.task?.cancel()
            self.task = nil
            self.session?.invalidateAndCancel()
            self.session = nil
        }
    }

    private func connect() {
        guard !stopped else { return }
        guard let token = tokenProvider() else {
            fatal(HivePushError(code: "invalid_user_token", message: "Call setUser(id:token:) before using the inbox"))
            return
        }
        let req: URLRequest
        do {
            var r = try transport.makeRequest("GET", "stream", query: [URLQueryItem(name: "user_token", value: token)])
            r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            r.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            r.timeoutInterval = 60 // the stream pings every 25 s
            req = r
        } catch {
            fatal(HivePushError(code: "invalid_options", message: "\(error)"))
            return
        }
        let config = transport.session.configuration
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let s = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        session = s
        parser = SSEParser()
        status = 0
        errorBody = Data()
        retryAfter = nil
        let t = s.dataTask(with: req)
        task = t
        t.resume()
    }

    private func fatal(_ err: HivePushError) {
        stopped = true
        session?.invalidateAndCancel()
        session = nil
        task = nil
        onFatal?(err)
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        var wait = delay + Double.random(in: 0...(delay / 2))
        if let ra = retryAfter { wait = max(wait, ra) }
        delay = min(delay * 2, maxDelay)
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in self?.connect() }
    }

    // MARK: URLSessionDataDelegate (called on `queue`)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        status = http?.statusCode ?? 0
        if status == 200 {
            delay = initialDelay
        } else if let ra = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) {
            retryAfter = ra
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard session === self.session, !stopped else { return }
        guard status == 200 else {
            if errorBody.count < 16_384 { errorBody.append(data) }
            return
        }
        for ev in parser.feed(data) where ev.event == "notification" {
            if let d = ev.data.data(using: .utf8), let item = try? JSONDecoder().decode(InboxItem.self, from: d) {
                onItem?(item)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        guard session === self.session, !stopped else { return }
        self.session = nil
        self.task = nil
        // 401 (expired user token, unknown key), 403 and 404 do not get better by retrying.
        if [400, 401, 403, 404].contains(status) {
            fatal(Transport.error(status: status, body: errorBody))
            return
        }
        scheduleReconnect()
    }
}
