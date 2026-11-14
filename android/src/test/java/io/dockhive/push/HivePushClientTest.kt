package io.dockhive.push

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.util.concurrent.TimeUnit

class HivePushClientTest {
    private lateinit var server: MockWebServer
    private lateinit var store: MemoryDeviceStore

    private val itemJson =
        """{"id":"inb_1","notification_id":"ntf_1","created_at":"2026-11-12T09:00:00.123Z","read_at":null,""" +
            """"title":"Shipped","body":"Thursday","url":"https://shop.example/o/77","data":{"order_id":77,"tags":["a"]},""" +
            """"actions":[{"action":"track","title":"Track","url":"/o/77/track"}]}"""

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        store = MemoryDeviceStore()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun client(): HivePushClient {
        val c = HivePushClient(
            "pk_test",
            server.url("/"),
            store,
            OkHttpClient.Builder().readTimeout(5, TimeUnit.SECONDS).build(),
        ) { DeviceInfo("1.2.3", "en-NG", "Africa/Lagos") }
        c.inbox.initialReconnectDelayMs = 20
        c.inbox.maxReconnectDelayMs = 50
        return c
    }

    private fun json(code: Int, body: String = "") =
        MockResponse().setResponseCode(code).setHeader("Content-Type", "application/json").setBody(body)

    private fun noContent() = MockResponse().setResponseCode(204)

    private fun RecordedRequest.json(): JSONObject = JSONObject(body.readUtf8())

    private fun route(handler: (RecordedRequest) -> MockResponse) {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest) = handler(request)
        }
    }

    private fun takeAll(): List<RecordedRequest> {
        val out = ArrayList<RecordedRequest>()
        while (true) out.add(server.takeRequest(100, TimeUnit.MILLISECONDS) ?: return out)
    }

    @Test
    fun baseUrlFromRegionAndHost() {
        assertEquals("https://push-global-1.dockhive.io/", Transport.baseUrl(region = "Global-1").toString())
        assertEquals("https://push-eu.dockhive.io/", Transport.baseUrl(host = "push-eu.dockhive.io/").toString())
        assertEquals("http://localhost:8080/", Transport.baseUrl(host = "http://localhost:8080").toString())
        try {
            Transport.baseUrl()
            fail("expected an error")
        } catch (e: HivePushException) {
            assertEquals("invalid_options", e.code)
        }
    }

    @Test
    fun refusesSecretKey() {
        try {
            HivePushClient("sk_secret", server.url("/"), store, OkHttpClient()) { DeviceInfo(null, null, null) }
            fail("expected an error")
        } catch (e: HivePushException) {
            assertEquals("invalid_options", e.code)
        }
    }

    @Test
    fun sanitizesDeviceInfo() {
        assertEquals("en-NG", DeviceInfo.sanitizeLocale("en_NG"))
        assertNull(DeviceInfo.sanitizeLocale("x"))
        assertNull(DeviceInfo.sanitizeTimezone("GMT+01:00"))
        assertEquals("Africa/Lagos", DeviceInfo.sanitizeTimezone("Africa/Lagos"))
        assertNull(DeviceInfo.sanitizeVersion("1".repeat(33)))
    }

    @Test
    fun registerPostsDeviceAndKeepsId() = runBlocking {
        server.enqueue(json(201, """{"device_id":"dev_aaaaaaaaaaaaaaaa"}"""))
        val c = client()
        assertEquals("dev_aaaaaaaaaaaaaaaa", c.register("fcm-token-1"))
        assertEquals("dev_aaaaaaaaaaaaaaaa", c.deviceId)
        assertEquals("fcm-token-1", store.token)

        val r = server.takeRequest()
        assertEquals("POST", r.method)
        assertEquals("/sdk/v1/devices", r.path)
        assertEquals("pk_test", r.getHeader("X-Hive-Push-Key"))
        assertTrue(r.getHeader("Content-Type")!!.startsWith("application/json"))
        assertNull(r.getHeader("Origin"))
        val b = r.json()
        assertEquals("android", b.getString("platform"))
        assertEquals("fcm-token-1", b.getString("token"))
        assertFalse(b.has("environment"))
        assertEquals("1.2.3", b.getString("app_version"))
        assertEquals("en-NG", b.getString("locale"))
        assertEquals("Africa/Lagos", b.getString("timezone"))
        assertFalse(b.has("user_token"))
        assertFalse(b.has("tags"))
    }

    @Test
    fun userAndTagsBeforeRegisterGoInTheRegistration() = runBlocking {
        server.enqueue(json(201, """{"device_id":"dev_1"}"""))
        val c = client()
        c.setUser("user-42", "ut.abc")
        c.setTags(mapOf("plan" to "pro"))
        assertEquals(0, server.requestCount)
        c.register("tok")
        val b = server.takeRequest().json()
        assertEquals("ut.abc", b.getString("user_token"))
        assertEquals("pro", b.getJSONObject("tags").getString("plan"))
        assertEquals("user-42", c.userId)
    }

    @Test
    fun newTokenReplacesOldDevice() = runBlocking {
        var n = 0
        route { r -> if (r.method == "DELETE") noContent() else json(201, """{"device_id":"dev_${++n}"}""") }
        val c = client()
        c.register("tok-1")
        c.register("tok-2")
        assertEquals("dev_2", c.deviceId)
        val reqs = takeAll()
        assertEquals(listOf("POST", "POST", "DELETE"), reqs.map { it.method })
        assertEquals("/sdk/v1/devices/dev_1", reqs[2].path)
    }

    @Test
    fun registerErrorCarriesCode() = runBlocking {
        server.enqueue(json(409, """{"error":"Android push is not set up for this app yet","code":"platform_not_configured"}"""))
        try {
            client().register("tok")
            fail("expected an error")
        } catch (e: HivePushException) {
            assertEquals("platform_not_configured", e.code)
            assertEquals(409, e.status)
        }
        assertNull(store.deviceId)
    }

    @Test
    fun errorWithoutJsonBody() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(502).setBody("bad gateway"))
        try {
            client().register("tok")
            fail("expected an error")
        } catch (e: HivePushException) {
            assertEquals("http_502", e.code)
            assertEquals(502, e.status)
        }
    }

    @Test
    fun networkErrorIsReported() = runBlocking {
        val c = client()
        server.shutdown()
        try {
            c.register("tok")
            fail("expected an error")
        } catch (e: HivePushException) {
            assertEquals("network", e.code)
            assertEquals(0, e.status)
        }
    }

    @Test
    fun setUserClearUserAndTagsPatch() = runBlocking {
        route { r -> if (r.method == "POST") json(201, """{"device_id":"dev_9"}""") else noContent() }
        val c = client()
        c.register("tok")
        c.setUser("user-42", "ut.1")
        c.setTags(mapOf("lang" to "en"))
        c.clearUser()
        val patches = takeAll().filter { it.method == "PATCH" }
        assertEquals(3, patches.size)
        assertTrue(patches.all { it.path == "/sdk/v1/devices/dev_9" })
        assertEquals("""{"user_token":"ut.1"}""", patches[0].body.readUtf8())
        assertEquals("""{"tags":{"lang":"en"}}""", patches[1].body.readUtf8())
        assertEquals("""{"user_id":null}""", patches[2].body.readUtf8())
        assertNull(c.userId)
    }

    @Test
    fun patchOnUnknownDeviceRegistersAgain() = runBlocking {
        var posts = 0
        route { r ->
            when (r.method) {
                "POST" -> json(201, """{"device_id":"dev_${++posts}"}""")
                "PATCH" -> json(404, """{"error":"Device not found.","code":"not_found"}""")
                else -> noContent()
            }
        }
        val c = client()
        c.register("tok")
        c.setUser("user-1", "ut.x")
        assertEquals("dev_2", c.deviceId)
        val last = takeAll().last { it.method == "POST" }.json()
        assertEquals("ut.x", last.getString("user_token"))
        assertEquals("tok", last.getString("token"))
    }

    @Test
    fun unregisterDeletesAndForgets() = runBlocking {
        route { r -> if (r.method == "POST") json(201, """{"device_id":"dev_5"}""") else json(404, """{"code":"not_found","error":"gone"}""") }
        val c = client()
        c.register("tok")
        c.unregister() // 404 is fine
        assertNull(c.deviceId)
        assertNull(store.token)
        c.unregister() // nothing to remove: nothing sent
        val reqs = takeAll()
        assertEquals(listOf("POST", "DELETE"), reqs.map { it.method })
        assertEquals("/sdk/v1/devices/dev_5", reqs[1].path)
    }

    @Test
    fun reportOpenedPostsClicked() = runBlocking {
        route { r -> if (r.path == "/sdk/v1/devices") json(201, """{"device_id":"dev_7"}""") else noContent() }
        val c = client()
        val data = mapOf("hp_id" to "ntf_5b0c9d2e7f1a3c4b", "hp_url" to "https://shop.example/o/77", "order_id" to "77")
        assertFalse("not registered yet", c.reportOpened(data))
        c.register("tok")
        assertTrue(c.reportOpened(data))
        assertFalse(c.reportOpened(mapOf("other" to "x")))
        val ev = takeAll().last()
        assertEquals("/sdk/v1/events", ev.path)
        val b = ev.json()
        assertEquals("dev_7", b.getString("device_id"))
        assertEquals("ntf_5b0c9d2e7f1a3c4b", b.getString("notification_id"))
        assertEquals("clicked", b.getString("type"))
        assertEquals("https://shop.example/o/77", HivePush.url(data))
        assertTrue(HivePush.isHivePushMessage(data))
    }

    @Test
    fun inboxNeedsUser() = runBlocking {
        try {
            client().inbox.list()
            fail("expected an error")
        } catch (e: HivePushException) {
            assertEquals("invalid_user_token", e.code)
        }
    }

    @Test
    fun inboxListAndMarkRead() = runBlocking {
        route { r -> if (r.path!!.startsWith("/sdk/v1/inbox?")) json(200, """{"items":[$itemJson],"unread":3}""") else noContent() }
        val c = client()
        c.setUser("user-42", "ut.abc")
        val page = c.inbox.list(before = "inb_9", limit = 20)
        assertEquals(3, page.unread)
        val it = page.items.single()
        assertEquals("inb_1", it.id)
        assertEquals("ntf_1", it.notificationId)
        assertFalse(it.isRead)
        assertEquals("Shipped", it.title)
        assertEquals(77, it.data["order_id"])
        assertEquals(listOf("a"), it.data["tags"])
        assertEquals(InboxAction("track", "Track", "/o/77/track"), it.actions.single())

        c.inbox.markRead(listOf("inb_1", "inb_2"))
        c.inbox.markAllRead()
        val reqs = takeAll()
        val list = reqs[0].requestUrl!!
        assertEquals("GET", reqs[0].method)
        assertEquals("ut.abc", list.queryParameter("user_token"))
        assertEquals("inb_9", list.queryParameter("before"))
        assertEquals("20", list.queryParameter("limit"))
        val read1 = reqs[1].json()
        assertEquals("ut.abc", read1.getString("user_token"))
        assertEquals("[\"inb_1\",\"inb_2\"]", read1.getJSONArray("ids").toString())
        val read2 = reqs[2].json()
        assertEquals("ut.abc", read2.getString("user_token"))
        assertTrue(read2.getBoolean("all"))
    }

    @Test
    fun sseParser() {
        val p = SseParser()
        val lines = "retry: 3000\n: connected\n\nid: inb_1\nevent: notification\ndata: {\"a\":1}\n\n: ping\n\ndata: x\ndata: y\n\n".split("\n")
        val events = lines.mapNotNull { p.line(it) }
        assertEquals(
            listOf(SseParser.Event("inb_1", "notification", """{"a":1}"""), SseParser.Event("inb_1", "message", "x\ny")),
            events,
        )
    }

    @Test
    fun streamReconnectsAndFailsOnExpiredToken() = runBlocking {
        var n = 0
        route { r ->
            if (!r.path!!.startsWith("/sdk/v1/stream")) return@route noContent()
            when (++n) {
                1 -> json(503, """{"code":"unavailable","error":"Restarting"}""")
                2 -> MockResponse().setResponseCode(200).setHeader("Content-Type", "text/event-stream")
                    .setBody("retry: 3000\n: connected\n\nid: inb_1\nevent: notification\ndata: $itemJson\n\n")
                else -> json(401, """{"code":"invalid_user_token","error":"expired"}""")
            }
        }
        val c = client()
        c.setUser("user-42", "ut.abc")
        val got = ArrayList<InboxItem>()
        try {
            withTimeout(5_000) { c.inbox.stream().collect { got.add(it) } }
            fail("expected an error")
        } catch (e: HivePushException) {
            assertEquals("invalid_user_token", e.code)
            assertEquals(401, e.status)
        }
        assertEquals(listOf("inb_1"), got.map { it.id })
        val streams = takeAll().filter { it.path!!.startsWith("/sdk/v1/stream") }
        assertEquals(3, streams.size)
        assertEquals("ut.abc", streams[0].requestUrl!!.queryParameter("user_token"))
        assertEquals("text/event-stream", streams[0].getHeader("Accept"))
    }

    @Test
    fun streamKeepsGoingAcrossReconnects() = runBlocking {
        route {
            MockResponse().setResponseCode(200).setHeader("Content-Type", "text/event-stream")
                .setBody("event: notification\ndata: $itemJson\n\n")
        }
        val c = client()
        c.setUser("user-42", "ut.abc")
        val items = withTimeout(5_000) { c.inbox.stream().take(2).toList() }
        assertEquals(listOf("inb_1", "inb_1"), items.map { it.id })
    }

    @Test
    fun clearUserEndsStreams() = runBlocking {
        route { r ->
            if (r.path!!.startsWith("/sdk/v1/stream")) {
                MockResponse().setResponseCode(200).setHeader("Content-Type", "text/event-stream")
                    .setBody(": connected\n\n").setBodyDelay(0, TimeUnit.MILLISECONDS)
            } else {
                noContent()
            }
        }
        val c = client()
        c.setUser("user-42", "ut.abc")
        val job = launch {
            c.inbox.stream().collect { }
        }
        // wait for the first connection
        withTimeout(5_000) { while (server.requestCount == 0) kotlinx.coroutines.delay(10) }
        c.clearUser()
        withTimeout(5_000) { job.join() } // the flow completed
        assertNull(c.userId)
    }

    @Test
    fun firstItemThenCancel() = runBlocking {
        route {
            MockResponse().setResponseCode(200).setHeader("Content-Type", "text/event-stream")
                .setBody("event: notification\ndata: $itemJson\n\n")
        }
        val c = client()
        c.setUser("user-42", "ut.abc")
        val first = withTimeout(5_000) { c.inbox.stream().first() }
        assertEquals("Shipped", first.title)
    }
}
