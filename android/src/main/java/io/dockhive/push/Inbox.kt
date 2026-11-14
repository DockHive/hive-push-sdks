package io.dockhive.push

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.ProducerScope
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import okhttp3.Call
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import kotlin.random.Random

/** The in-app inbox of the user set with [HivePushClient.setUser]. */
class Inbox internal constructor(
    private val transport: Transport,
    private val tokenProvider: () -> String?,
) {
    /** Reconnect backoff in milliseconds: starts here and doubles up to [maxReconnectDelayMs]. */
    internal var initialReconnectDelayMs = 1_000L
    internal var maxReconnectDelayMs = 30_000L

    private val streamHttp by lazy {
        // The stream pings every 25 s; anything quieter than a minute is a dead connection.
        transport.http.newBuilder().readTimeout(60, TimeUnit.SECONDS).callTimeout(0, TimeUnit.SECONDS).build()
    }

    private class Live(val scope: ProducerScope<InboxItem>) {
        @Volatile var call: Call? = null
    }

    private val live = ConcurrentHashMap.newKeySet<Live>()

    private fun needToken(): String = tokenProvider()
        ?: throw HivePushException("invalid_user_token", "Call setUser(userId, token) before using the inbox")

    /**
     * The user's inbox, newest first. Pass the last item's `id` as [before] for the next page;
     * [limit] is at most 50.
     */
    suspend fun list(before: String? = null, limit: Int? = null): InboxPage {
        val text = transport.send(
            "GET", "inbox",
            query = mapOf("user_token" to needToken(), "before" to before, "limit" to limit?.toString()),
        )
        return try {
            val o = JSONObject(text)
            val arr = o.optJSONArray("items") ?: JSONArray()
            InboxPage((0 until arr.length()).map { InboxItem.fromJson(arr.getJSONObject(it)) }, o.optInt("unread"))
        } catch (e: Exception) {
            throw HivePushException("invalid_response", "Unexpected answer from Hive Push: ${e.message}", 0, e)
        }
    }

    /** Marks these items as read. */
    suspend fun markRead(ids: List<String>) {
        transport.send("POST", "inbox/read", body = JSONObject().put("user_token", needToken()).put("ids", JSONArray(ids)))
    }

    /** Marks one item as read. */
    suspend fun markRead(id: String) = markRead(listOf(id))

    /** Marks every item as read. */
    suspend fun markAllRead() {
        transport.send("POST", "inbox/read", body = JSONObject().put("user_token", needToken()).put("all", true))
    }

    /**
     * The live inbox: emits every new item while collected. Reconnects on its own (1 s, doubling
     * to 30 s). Fails with a [HivePushException] on an error that a retry cannot fix (for example
     * an expired user token: call `setUser` with a fresh token and collect again). Completes when
     * the user signs out ([HivePushClient.clearUser]) or changes.
     *
     * Items arrive on the collector's context, so collecting in `lifecycleScope` delivers them on
     * the main thread.
     */
    fun stream(): Flow<InboxItem> = callbackFlow {
        val me = Live(this)
        live.add(me)
        val worker = launch(Dispatchers.IO) {
            var delayMs = initialReconnectDelayMs
            while (isActive) {
                val token = tokenProvider()
                if (token == null) {
                    close(HivePushException("invalid_user_token", "Call setUser(userId, token) before using the inbox"))
                    return@launch
                }
                val req = transport.request("GET", "stream", mapOf("user_token" to token)).newBuilder()
                    .header("Accept", "text/event-stream")
                    .header("Cache-Control", "no-cache")
                    .build()
                val call = streamHttp.newCall(req)
                me.call = call
                var retryAfterMs = 0L
                try {
                    call.execute().use { r ->
                        when {
                            r.code == 200 -> {
                                delayMs = initialReconnectDelayMs
                                val parser = SseParser()
                                val source = r.body!!.source()
                                while (isActive) {
                                    val line = source.readUtf8Line() ?: break
                                    val ev = parser.line(line) ?: continue
                                    if (ev.event != "notification") continue
                                    val item = try {
                                        InboxItem.fromJson(JSONObject(ev.data))
                                    } catch (_: Exception) {
                                        null
                                    }
                                    if (item != null) send(item)
                                }
                            }
                            // An expired user token, unknown key or refused request does not get better by retrying.
                            r.code in FATAL -> {
                                close(Transport.error(r.code, r.body?.string()))
                                return@launch
                            }
                            else -> retryAfterMs = (r.header("Retry-After")?.toLongOrNull() ?: 0L) * 1000
                        }
                    }
                } catch (_: IOException) {
                    // dropped or cancelled: reconnect below unless stopped
                }
                if (!isActive) return@launch
                val wait = maxOf(delayMs + Random.nextLong(0, delayMs / 2 + 1), retryAfterMs)
                delayMs = minOf(delayMs * 2, maxReconnectDelayMs)
                delay(wait)
            }
        }
        awaitClose {
            live.remove(me)
            me.call?.cancel()
            worker.cancel()
        }
    }.buffer(64)

    /** Ends every live stream (the user signed out or changed). */
    internal fun stopAll() {
        for (l in live.toList()) {
            live.remove(l)
            l.call?.cancel()
            l.scope.close()
        }
    }

    private companion object {
        val FATAL = setOf(400, 401, 403, 404)
    }
}
