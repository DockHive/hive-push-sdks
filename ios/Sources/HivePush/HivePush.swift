import Foundation

/// The Hive Push client for iOS apps.
///
/// ```swift
/// HivePush.configure(key: "pk_...", region: "global-1")
/// try await HivePush.shared.register(deviceToken: deviceToken)
/// try await HivePush.shared.setUser(id: "user-42", token: tokenFromYourServer)
/// ```
public final class HivePush: @unchecked Sendable {
    public static let sdkVersion = "0.1.0"

    // MARK: - Shared instance

    private static let sharedLock = NSLock()
    private static var _shared: HivePush?

    /// The client set up by `configure`. Calling it before `configure` is a programmer error.
    public static var shared: HivePush {
        guard let s = sharedLock.locked({ _shared }) else {
            fatalError("HivePush: call HivePush.configure(key:region:) before using HivePush.shared")
        }
        return s
    }

    /// Sets up the shared client with the app's public key (`pk_...`) and its
    /// region (for example `global-1`), as shown on the app's page in the console.
    @discardableResult
    public static func configure(key: String, region: String) -> HivePush {
        guard let url = hivePushBaseURL(region: region) else {
            fatalError("HivePush.configure: region must not be empty")
        }
        return install(HivePush(key: key, baseURL: url))
    }

    /// Sets up the shared client with an explicit host (for example `push-global-1.dockhive.io`).
    @discardableResult
    public static func configure(key: String, host: String) -> HivePush {
        guard let url = hivePushBaseURL(host: host) else {
            fatalError("HivePush.configure: host must not be empty")
        }
        return install(HivePush(key: key, baseURL: url))
    }

    private static func install(_ client: HivePush) -> HivePush {
        sharedLock.locked { _shared = client }
        return client
    }

    // MARK: - Instance

    let transport: Transport
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var userToken: String?
    private var currentUserId: String?
    private var pendingTags: [String: String]?
    var deviceInfo: () -> DeviceInfo = { DeviceInfo.current() }

    /// The in-app inbox of the signed-in user (after `setUser`).
    public private(set) lazy var inbox = Inbox(transport: transport, tokenProvider: { [weak self] in self?.currentUserToken })

    /// Creates a client. Most apps use `HivePush.configure` and `HivePush.shared`
    /// instead; this is for apps that need several clients or a custom `URLSession`.
    public init(key: String, baseURL: URL, session: URLSession = .shared, defaults: UserDefaults = .standard) {
        precondition(key.hasPrefix("pk_"), "HivePush: use the app's public key (pk_...), never the secret key")
        self.transport = Transport(baseURL: baseURL, key: key, session: session)
        self.defaults = defaults
    }

    private var storagePrefix: String { "hivepush.\(transport.key)." }

    /// This install's device id (`dev_...`), kept across launches; nil until registered.
    public var deviceId: String? {
        defaults.string(forKey: storagePrefix + "deviceId")
    }

    /// The user set with `setUser`, or nil.
    public var userId: String? {
        lock.locked { currentUserId }
    }

    var currentUserToken: String? {
        lock.locked { userToken }
    }

    private var storedToken: String? { defaults.string(forKey: storagePrefix + "token") }
    private var storedEnvironment: APNsEnvironment? {
        defaults.string(forKey: storagePrefix + "environment").flatMap(APNsEnvironment.init(rawValue:))
    }

    private func store(deviceId: String?, token: String?, environment: APNsEnvironment?) {
        let p = storagePrefix
        defaults.set(deviceId, forKey: p + "deviceId")
        defaults.set(token, forKey: p + "token")
        defaults.set(environment?.rawValue, forKey: p + "environment")
    }

    // MARK: - Registration

    /// Registers this install's APNs device token. Call it from
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` on every
    /// launch: registering the same token again just refreshes it, and a new token
    /// replaces the old device.
    ///
    /// - Returns: the device id.
    @discardableResult
    public func register(deviceToken: Data, environment: APNsEnvironment = .auto) async throws -> String {
        try await register(tokenHex: deviceToken.hexString, environment: environment)
    }

    /// Registers an APNs device token given as hex.
    @discardableResult
    public func register(tokenHex: String, environment: APNsEnvironment = .auto) async throws -> String {
        let token = tokenHex.lowercased()
        let env = environment.resolved
        var body: [String: Any] = ["platform": "ios", "token": token, "environment": env.rawValue]
        for (k, v) in deviceInfo().fields() { body[k] = v }
        lock.locked {
            if let t = userToken { body["user_token"] = t }
            if let tags = pendingTags { body["tags"] = tags }
        }

        let data = try await transport.send("POST", "devices", body: body)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = obj["device_id"] as? String else {
            throw HivePushError(code: "invalid_response", message: "Registration answered without a device_id")
        }
        let previousId = deviceId
        store(deviceId: id, token: token, environment: env)
        if let old = previousId, old != id {
            // The token changed: the old device can no longer receive anything.
            _ = try? await transport.send("DELETE", "devices/\(pathEscape(old))")
        }
        return id
    }

    /// Re-registers the last token (used when the server no longer knows the device).
    private func reRegister() async throws {
        guard let token = storedToken else { return }
        defaults.removeObject(forKey: storagePrefix + "deviceId")
        try await register(tokenHex: token, environment: storedEnvironment ?? .auto)
    }

    /// PATCHes this device; no-op before registration (the change is sent with it).
    private func patchDevice(_ body: [String: Any]) async throws {
        guard let id = deviceId else { return }
        do {
            try await transport.send("PATCH", "devices/\(pathEscape(id))", body: body)
        } catch let e as HivePushError where e.status == 404 {
            // The device was removed on the server (for example the user's data was
            // deleted): register again with the current user and tags.
            try await reRegister()
        }
    }

    // MARK: - User and tags

    /// Attaches your signed-in user to this install and enables the inbox.
    /// `token` is a user token made by your server with the app's secret key.
    /// Can be called before or after `register`.
    public func setUser(id: String, token: String) async throws {
        guard !token.isEmpty else {
            throw HivePushError(code: "invalid_user_token", message: "setUser needs the user token from your server")
        }
        let changedUser: Bool = lock.locked {
            let changed = currentUserId != nil && currentUserId != id
            currentUserId = id
            userToken = token
            return changed
        }
        if changedUser { inbox.stopAll() }
        try await patchDevice(["user_token": token])
    }

    /// Signs the user out: the install keeps receiving app-wide notifications but
    /// no longer belongs to the user. Live inbox streams stop.
    public func clearUser() async throws {
        lock.locked {
            currentUserId = nil
            userToken = nil
        }
        inbox.stopAll()
        try await patchDevice(["user_id": NSNull()])
    }

    /// Replaces this install's tags (string values, at most 20 keys).
    public func setTags(_ tags: [String: String]) async throws {
        lock.locked { pendingTags = tags }
        try await patchDevice(["tags": tags])
    }

    /// Removes this install from Hive Push (for example when the user turns
    /// notifications off). Register again to receive notifications.
    public func unregister() async throws {
        guard let id = deviceId else { return }
        store(deviceId: nil, token: nil, environment: nil)
        do {
            try await transport.send("DELETE", "devices/\(pathEscape(id))")
        } catch let e as HivePushError where e.status == 404 {
            // already gone
        }
    }

    // MARK: - Events

    /// The Hive Push notification id (`hp.id`) of a notification's `userInfo`,
    /// or nil when the notification is not from Hive Push.
    public static func notificationId(from userInfo: [AnyHashable: Any]) -> String? {
        (userInfo["hp"] as? [String: Any])?["id"] as? String
    }

    /// The notification's link (`hp.url`), if it has one.
    public static func url(from userInfo: [AnyHashable: Any]) -> URL? {
        ((userInfo["hp"] as? [String: Any])?["url"] as? String).flatMap(URL.init(string:))
    }

    /// The notification's `data` object (`hp.data`), if it has one.
    public static func data(from userInfo: [AnyHashable: Any]) -> [String: Any]? {
        (userInfo["hp"] as? [String: Any])?["data"] as? [String: Any]
    }

    /// Reports that the user opened (tapped) a notification, so it counts in your
    /// stats. Call it from `userNotificationCenter(_:didReceive:withCompletionHandler:)`
    /// (or use `HivePushNotificationDelegate`).
    ///
    /// - Returns: false when the notification is not from Hive Push or the
    ///   install is not registered (nothing is sent).
    @discardableResult
    public func reportOpened(userInfo: [AnyHashable: Any]) async throws -> Bool {
        guard let nid = HivePush.notificationId(from: userInfo) else { return false }
        return try await report(.clicked, notificationId: nid)
    }

    /// Reports a `delivered`, `clicked` or `dismissed` event for a notification.
    @discardableResult
    public func report(_ type: HivePushEventType, notificationId: String) async throws -> Bool {
        guard let id = deviceId else { return false }
        try await transport.send("POST", "events", body: [
            "device_id": id, "notification_id": notificationId, "type": type.rawValue,
        ])
        return true
    }
}

extension NSLock {
    /// Runs `body` while holding the lock (usable from async code).
    @discardableResult
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

func pathEscape(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s
}
