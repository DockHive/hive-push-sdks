import Foundation

/// A running live inbox stream. Call `cancel()` to stop it.
public final class HivePushSubscription: @unchecked Sendable {
    private let onCancel: () -> Void
    private let lock = NSLock()
    private var cancelled = false

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        let first = !cancelled
        cancelled = true
        lock.unlock()
        if first { onCancel() }
    }
}

/// The in-app inbox of the user set with `HivePush.setUser`.
public final class Inbox: @unchecked Sendable {
    private let transport: Transport
    private let tokenProvider: () -> String?
    private let lock = NSLock()
    private var streams: [ObjectIdentifier: EventStreamConnection] = [:]

    /// Reconnect backoff: starts here and doubles up to `maxReconnectDelay`.
    var initialReconnectDelay: TimeInterval = 1
    var maxReconnectDelay: TimeInterval = 30

    init(transport: Transport, tokenProvider: @escaping () -> String?) {
        self.transport = transport
        self.tokenProvider = tokenProvider
    }

    private func needToken() throws -> String {
        guard let t = tokenProvider() else {
            throw HivePushError(code: "invalid_user_token", message: "Call setUser(id:token:) before using the inbox")
        }
        return t
    }

    /// The user's inbox, newest first. Pass the last item's `id` as `before` for
    /// the next page; `limit` is at most 50.
    public func list(before: String? = nil, limit: Int? = nil) async throws -> InboxPage {
        var q = [URLQueryItem(name: "user_token", value: try needToken())]
        if let b = before { q.append(URLQueryItem(name: "before", value: b)) }
        if let l = limit { q.append(URLQueryItem(name: "limit", value: String(l))) }
        let data = try await transport.send("GET", "inbox", query: q)
        return try Transport.decode(InboxPage.self, from: data)
    }

    /// Marks these items as read.
    public func markRead(_ ids: [String]) async throws {
        try await transport.send("POST", "inbox/read", body: ["user_token": try needToken(), "ids": ids])
    }

    /// Marks one item as read.
    public func markRead(_ id: String) async throws {
        try await markRead([id])
    }

    /// Marks every item as read.
    public func markAllRead() async throws {
        try await transport.send("POST", "inbox/read", body: ["user_token": try needToken(), "all": true])
    }

    /// Live inbox: calls `handler` on the main actor for every new item. Reconnects
    /// on its own (1 s, doubling to 30 s). Stops for good on an error that a retry
    /// cannot fix (for example an expired user token), which is passed to `onError`;
    /// call `setUser` with a fresh token and start it again.
    @discardableResult
    public func onMessage(
        _ handler: @escaping @MainActor (InboxItem) -> Void,
        onError: (@MainActor (HivePushError) -> Void)? = nil
    ) -> HivePushSubscription {
        let conn = EventStreamConnection(
            transport: transport,
            tokenProvider: tokenProvider,
            initialDelay: initialReconnectDelay,
            maxDelay: maxReconnectDelay
        )
        let key = ObjectIdentifier(conn)
        conn.onItem = { item in
            onMain { handler(item) }
        }
        conn.onFatal = { [weak self] err in
            self?.remove(key)
            if let onError = onError { onMain { onError(err) } }
        }
        lock.lock()
        streams[key] = conn
        lock.unlock()
        conn.start()
        return HivePushSubscription { [weak self, weak conn] in
            conn?.stop()
            self?.remove(key)
        }
    }

    /// Live inbox as an `AsyncStream`; the stream ends when the task is cancelled
    /// or on an error a retry cannot fix.
    public func messages() -> AsyncStream<InboxItem> {
        AsyncStream { continuation in
            let sub = self.onMessage({ item in
                continuation.yield(item)
            }, onError: { _ in
                continuation.finish()
            })
            continuation.onTermination = { _ in sub.cancel() }
        }
    }

    private func remove(_ key: ObjectIdentifier) {
        lock.lock()
        streams[key] = nil
        lock.unlock()
    }

    /// Stops every live stream (when the user changes or signs out).
    func stopAll() {
        lock.lock()
        let all = Array(streams.values)
        streams.removeAll()
        lock.unlock()
        all.forEach { $0.stop() }
    }
}

/// Runs `body` on the main actor, in order.
func onMain(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated { body() }
    }
}
