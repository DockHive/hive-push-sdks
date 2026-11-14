import XCTest
@testable import HivePush

final class HivePushTests: XCTestCase {
    var defaults: UserDefaults!
    var suite: String!
    let base = URL(string: "https://push-test-1.dockhive.io")!
    let tokenData = Data((0..<32).map { UInt8($0) })
    var tokenHex: String { tokenData.map { String(format: "%02x", $0) }.joined() }
    let itemJSON = #"{"id":"inb_1","notification_id":"ntf_1","created_at":"2026-11-12T09:00:00.123Z","read_at":null,"title":"Shipped","body":"Thursday","url":"https://shop.example/o/77","data":{"order_id":77,"rush":true}}"#

    override func setUp() {
        super.setUp()
        suite = "hivepush-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func makeClient() -> HivePush {
        let c = HivePush(key: "pk_test", baseURL: base, session: StubProtocol.session(), defaults: defaults)
        c.deviceInfo = { DeviceInfo(appVersion: "1.2.3", locale: "en-NG", timezone: "Africa/Lagos") }
        c.inbox.initialReconnectDelay = 0.05
        c.inbox.maxReconnectDelay = 0.1
        return c
    }

    // MARK: - Configuration

    func testBaseURLFromRegionAndHost() {
        XCTAssertEqual(hivePushBaseURL(region: "Global-1")?.absoluteString, "https://push-global-1.dockhive.io")
        XCTAssertEqual(hivePushBaseURL(host: "push-eu.dockhive.io/")?.absoluteString, "https://push-eu.dockhive.io")
        XCTAssertEqual(hivePushBaseURL(host: "http://localhost:8080")?.absoluteString, "http://localhost:8080")
        XCTAssertNil(hivePushBaseURL(region: " "))
    }

    func testConfigureSetsShared() {
        let c = HivePush.configure(key: "pk_shared", region: "global-1")
        XCTAssertTrue(HivePush.shared === c)
        XCTAssertEqual(c.transport.baseURL.absoluteString, "https://push-global-1.dockhive.io")
    }

    func testEnvironmentAutoIsSandboxInDebug() {
        #if DEBUG
        XCTAssertEqual(APNsEnvironment.auto.resolved, .sandbox)
        #else
        XCTAssertEqual(APNsEnvironment.auto.resolved, .production)
        #endif
        XCTAssertEqual(APNsEnvironment.production.resolved, .production)
    }

    func testLocaleAndTimezoneSanitizing() {
        XCTAssertEqual(DeviceInfo.sanitizeLocale("en_NG@calendar=gregorian"), "en-NG")
        XCTAssertEqual(DeviceInfo.sanitizeLocale("zh-Hans_CN"), "zh-Hans-CN")
        XCTAssertNil(DeviceInfo.sanitizeLocale("x"))
        XCTAssertNil(DeviceInfo.sanitizeTimezone("GMT+01:00"))
        XCTAssertEqual(DeviceInfo.sanitizeTimezone("Africa/Lagos"), "Africa/Lagos")
        XCTAssertNil(DeviceInfo.sanitizeVersion(String(repeating: "1", count: 33)))
    }

    // MARK: - Registration

    func testRegisterPostsDeviceAndPersistsId() async throws {
        StubProtocol.reset { _ in .json(201, #"{"device_id":"dev_aaaaaaaaaaaaaaaa"}"#) }
        let c = makeClient()
        let id = try await c.register(deviceToken: tokenData, environment: .production)
        XCTAssertEqual(id, "dev_aaaaaaaaaaaaaaaa")
        XCTAssertEqual(c.deviceId, "dev_aaaaaaaaaaaaaaaa")

        let r = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.absoluteString, "https://push-test-1.dockhive.io/sdk/v1/devices")
        XCTAssertEqual(r.headers["X-Hive-Push-Key"], "pk_test")
        XCTAssertEqual(r.headers["Content-Type"], "application/json")
        XCTAssertNil(r.headers["Origin"])
        XCTAssertEqual(r.json["platform"] as? String, "ios")
        XCTAssertEqual(r.json["token"] as? String, tokenHex)
        XCTAssertEqual(r.json["environment"] as? String, "production")
        XCTAssertEqual(r.json["app_version"] as? String, "1.2.3")
        XCTAssertEqual(r.json["locale"] as? String, "en-NG")
        XCTAssertEqual(r.json["timezone"] as? String, "Africa/Lagos")
        XCTAssertNil(r.json["user_token"])
        XCTAssertNil(r.json["tags"])

        // A new client with the same storage remembers the device.
        XCTAssertEqual(makeClient().deviceId, "dev_aaaaaaaaaaaaaaaa")
    }

    func testUserAndTagsBeforeRegisterGoInTheRegistration() async throws {
        StubProtocol.reset { _ in .json(201, #"{"device_id":"dev_1"}"#) }
        let c = makeClient()
        try await c.setUser(id: "user-42", token: "ut.abc")
        try await c.setTags(["plan": "pro"])
        XCTAssertTrue(StubProtocol.requests.isEmpty, "no PATCH before registration")
        try await c.register(deviceToken: tokenData, environment: .sandbox)
        let r = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(r.json["user_token"] as? String, "ut.abc")
        XCTAssertEqual(r.json["tags"] as? [String: String], ["plan": "pro"])
        XCTAssertEqual(r.json["environment"] as? String, "sandbox")
        XCTAssertEqual(c.userId, "user-42")
    }

    func testNewTokenReplacesOldDevice() async throws {
        var n = 0
        StubProtocol.reset { r in
            if r.method == "DELETE" { return .noContent() }
            n += 1
            return .json(201, #"{"device_id":"dev_\#(n)"}"#)
        }
        let c = makeClient()
        try await c.register(deviceToken: tokenData)
        try await c.register(tokenHex: String(repeating: "ab", count: 32))
        XCTAssertEqual(c.deviceId, "dev_2")
        let reqs = StubProtocol.requests
        XCTAssertEqual(reqs.map(\.method), ["POST", "POST", "DELETE"])
        XCTAssertEqual(reqs[2].path, "/sdk/v1/devices/dev_1")
    }

    func testSameTokenDoesNotDelete() async throws {
        StubProtocol.reset { _ in .json(200, #"{"device_id":"dev_1"}"#) }
        let c = makeClient()
        try await c.register(deviceToken: tokenData)
        try await c.register(deviceToken: tokenData)
        XCTAssertEqual(StubProtocol.requests.map(\.method), ["POST", "POST"])
    }

    func testRegisterErrorCarriesCode() async {
        StubProtocol.reset { _ in
            .json(409, #"{"error":"iOS push is not set up for this app yet","code":"platform_not_configured"}"#)
        }
        let c = makeClient()
        do {
            try await c.register(deviceToken: tokenData)
            XCTFail("expected an error")
        } catch let e as HivePushError {
            XCTAssertEqual(e.code, "platform_not_configured")
            XCTAssertEqual(e.status, 409)
            XCTAssertTrue(e.message.contains("not set up"))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertNil(c.deviceId)
    }

    func testErrorWithoutJSONBody() async {
        StubProtocol.reset { _ in StubResponse(status: 502, headers: [:], chunks: [Data("bad gateway".utf8)]) }
        do {
            try await makeClient().register(deviceToken: tokenData)
            XCTFail("expected an error")
        } catch let e as HivePushError {
            XCTAssertEqual(e.code, "http_502")
            XCTAssertEqual(e.status, 502)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - User, tags, unregister

    func testSetUserClearUserAndTagsPatch() async throws {
        StubProtocol.reset { r in r.method == "POST" ? .json(201, #"{"device_id":"dev_9"}"#) : .noContent() }
        let c = makeClient()
        try await c.register(deviceToken: tokenData)
        try await c.setUser(id: "user-42", token: "ut.1")
        try await c.setTags(["lang": "en"])
        try await c.clearUser()
        let patches = StubProtocol.requests.filter { $0.method == "PATCH" }
        XCTAssertEqual(patches.count, 3)
        XCTAssertTrue(patches.allSatisfy { $0.path == "/sdk/v1/devices/dev_9" })
        XCTAssertEqual(patches[0].json["user_token"] as? String, "ut.1")
        XCTAssertEqual(patches[1].json["tags"] as? [String: String], ["lang": "en"])
        XCTAssertTrue(patches[2].json["user_id"] is NSNull)
        XCTAssertEqual(String(decoding: patches[2].body, as: UTF8.self), #"{"user_id":null}"#)
        XCTAssertNil(c.userId)
    }

    func testSetUserRequiresToken() async {
        do {
            try await makeClient().setUser(id: "u", token: "")
            XCTFail("expected an error")
        } catch let e as HivePushError {
            XCTAssertEqual(e.code, "invalid_user_token")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testPatchOnUnknownDeviceRegistersAgain() async throws {
        var posts = 0
        StubProtocol.reset { r in
            switch r.method {
            case "POST":
                posts += 1
                return .json(201, #"{"device_id":"dev_\#(posts)"}"#)
            case "PATCH":
                return .json(404, #"{"error":"Device not found.","code":"not_found"}"#)
            default:
                return .noContent()
            }
        }
        let c = makeClient()
        try await c.register(deviceToken: tokenData, environment: .production)
        try await c.setUser(id: "user-1", token: "ut.x")
        XCTAssertEqual(c.deviceId, "dev_2")
        let last = try XCTUnwrap(StubProtocol.requests.last { $0.method == "POST" })
        XCTAssertEqual(last.json["user_token"] as? String, "ut.x")
        XCTAssertEqual(last.json["token"] as? String, tokenHex)
        XCTAssertEqual(last.json["environment"] as? String, "production")
    }

    func testUnregisterDeletesAndForgets() async throws {
        StubProtocol.reset { r in
            r.method == "POST" ? .json(201, #"{"device_id":"dev_5"}"#) : .json(404, #"{"code":"not_found","error":"gone"}"#)
        }
        let c = makeClient()
        try await c.register(deviceToken: tokenData)
        try await c.unregister() // 404 is fine
        XCTAssertNil(c.deviceId)
        XCTAssertEqual(StubProtocol.requests.last?.method, "DELETE")
        XCTAssertEqual(StubProtocol.requests.last?.path, "/sdk/v1/devices/dev_5")
        try await c.unregister() // no device: nothing sent
        XCTAssertEqual(StubProtocol.requests.count, 2)
    }

    // MARK: - Events

    func testReportOpenedPostsClicked() async throws {
        StubProtocol.reset { r in r.method == "POST" && r.path.hasSuffix("devices") ? .json(201, #"{"device_id":"dev_7"}"#) : .noContent() }
        let c = makeClient()
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Hi"]],
            "hp": ["id": "ntf_5b0c9d2e7f1a3c4b", "url": "https://shop.example/orders/77", "data": ["order_id": 77]],
        ]
        let before = try await c.reportOpened(userInfo: userInfo)
        XCTAssertFalse(before, "not registered yet")
        try await c.register(deviceToken: tokenData)
        let sent = try await c.reportOpened(userInfo: userInfo)
        XCTAssertTrue(sent)
        let r = try XCTUnwrap(StubProtocol.requests.last)
        XCTAssertEqual(r.path, "/sdk/v1/events")
        XCTAssertEqual(r.json["device_id"] as? String, "dev_7")
        XCTAssertEqual(r.json["notification_id"] as? String, "ntf_5b0c9d2e7f1a3c4b")
        XCTAssertEqual(r.json["type"] as? String, "clicked")
        XCTAssertEqual(HivePush.url(from: userInfo)?.absoluteString, "https://shop.example/orders/77")
        XCTAssertEqual(HivePush.data(from: userInfo)?["order_id"] as? Int, 77)

        let other = try await c.reportOpened(userInfo: ["aps": ["alert": "x"]])
        XCTAssertFalse(other)
    }

    // MARK: - Inbox

    func testInboxNeedsUser() async {
        do {
            _ = try await makeClient().inbox.list()
            XCTFail("expected an error")
        } catch let e as HivePushError {
            XCTAssertEqual(e.code, "invalid_user_token")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testInboxListAndMarkRead() async throws {
        let item = itemJSON
        StubProtocol.reset { r in
            r.path.hasSuffix("/inbox") ? .json(200, #"{"items":[\#(item)],"unread":3}"#) : .noContent()
        }
        let c = makeClient()
        try await c.setUser(id: "user-42", token: "ut.abc")
        let page = try await c.inbox.list(before: "inb_9", limit: 20)
        XCTAssertEqual(page.unread, 3)
        XCTAssertEqual(page.items.count, 1)
        let it = page.items[0]
        XCTAssertEqual(it.id, "inb_1")
        XCTAssertEqual(it.notificationId, "ntf_1")
        XCTAssertFalse(it.isRead)
        XCTAssertEqual(it.title, "Shipped")
        XCTAssertEqual(it.data?["order_id"], .number(77))
        XCTAssertEqual(it.data?["rush"], .bool(true))
        XCTAssertNotNil(it.createdDate)

        let r = StubProtocol.requests[0]
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.query("user_token"), "ut.abc")
        XCTAssertEqual(r.query("before"), "inb_9")
        XCTAssertEqual(r.query("limit"), "20")

        try await c.inbox.markRead(["inb_1", "inb_2"])
        try await c.inbox.markAllRead()
        let reads = StubProtocol.requests.filter { $0.path == "/sdk/v1/inbox/read" }
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(reads[0].json["ids"] as? [String], ["inb_1", "inb_2"])
        XCTAssertEqual(reads[0].json["user_token"] as? String, "ut.abc")
        XCTAssertEqual(reads[1].json["all"] as? Bool, true)
    }

    // MARK: - Live stream

    func testSSEParser() {
        var p = SSEParser()
        var events = p.feed(Data("retry: 3000\n: connected\n\nid: inb_1\nevent: notifi".utf8))
        XCTAssertTrue(events.isEmpty)
        events = p.feed(Data("cation\r\ndata: {\"a\":1}\n\n: ping\n\ndata: x\ndata: y\n\n".utf8))
        XCTAssertEqual(events, [
            SSEParser.Event(id: "inb_1", event: "notification", data: #"{"a":1}"#),
            SSEParser.Event(id: "inb_1", event: "message", data: "x\ny"),
        ])
    }

    func testStreamDeliversOnMainAndReconnects() async throws {
        let item = itemJSON
        var n = 0
        StubProtocol.reset { r in
            guard r.path == "/sdk/v1/stream" else { return .noContent() }
            n += 1
            switch n {
            case 1:
                return .json(503, #"{"code":"unavailable","error":"Restarting"}"#)
            case 2:
                return StubResponse(status: 200, headers: ["Content-Type": "text/event-stream"], chunks: [
                    Data("retry: 3000\n: connected\n\n".utf8),
                    Data("id: inb_1\nevent: notification\ndata: \(item)\n\n".utf8),
                ])
            default:
                return .json(401, #"{"code":"invalid_user_token","error":"expired"}"#)
            }
        }
        let c = makeClient()
        try await c.setUser(id: "user-42", token: "ut.abc")

        let got = expectation(description: "item")
        let failed = expectation(description: "fatal error")
        var received: [InboxItem] = []
        var fatal: HivePushError?
        let sub = c.inbox.onMessage({ item in
            XCTAssertTrue(Thread.isMainThread)
            received.append(item)
            got.fulfill()
        }, onError: { err in
            XCTAssertTrue(Thread.isMainThread)
            fatal = err
            failed.fulfill()
        })
        await fulfillment(of: [got, failed], timeout: 5, enforceOrder: true)
        XCTAssertEqual(received.map(\.id), ["inb_1"])
        XCTAssertEqual(fatal?.code, "invalid_user_token")
        XCTAssertEqual(fatal?.status, 401)
        let streams = StubProtocol.requests.filter { $0.path == "/sdk/v1/stream" }
        XCTAssertEqual(streams.count, 3)
        XCTAssertEqual(streams[0].query("user_token"), "ut.abc")
        XCTAssertEqual(streams[0].headers["Accept"], "text/event-stream")
        sub.cancel()
    }

    func testMessagesAsyncStream() async throws {
        let item = itemJSON
        StubProtocol.reset { r in
            StubResponse(status: 200, headers: ["Content-Type": "text/event-stream"], chunks: [
                Data("event: notification\ndata: \(item)\n\n".utf8),
            ])
        }
        let c = makeClient()
        try await c.setUser(id: "user-42", token: "ut.abc")
        var it = c.inbox.messages().makeAsyncIterator()
        let first = await it.next()
        let second = await it.next() // after a reconnect
        XCTAssertEqual(first?.id, "inb_1")
        XCTAssertEqual(second?.id, "inb_1")
        c.inbox.stopAll()
    }

    func testClearUserStopsStreams() async throws {
        StubProtocol.reset { r in
            r.path == "/sdk/v1/stream"
                ? StubResponse(status: 200, headers: ["Content-Type": "text/event-stream"], chunks: [Data(": connected\n\n".utf8)])
                : .noContent()
        }
        let c = makeClient()
        try await c.setUser(id: "user-42", token: "ut.abc")
        let sub = c.inbox.onMessage { _ in }
        try await Task.sleep(nanoseconds: 200_000_000)
        try await c.clearUser()
        try await Task.sleep(nanoseconds: 100_000_000)
        let count = StubProtocol.requests.filter { $0.path == "/sdk/v1/stream" }.count
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(StubProtocol.requests.filter { $0.path == "/sdk/v1/stream" }.count, count, "no reconnects after clearUser")
        XCTAssertGreaterThan(count, 0)
        sub.cancel()
    }
}
