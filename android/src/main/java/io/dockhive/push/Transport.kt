package io.dockhive.push

import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONObject
import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Sends requests to the Hive Push SDK endpoints (`/sdk/v1/...`). */
internal class Transport(val baseUrl: HttpUrl, val key: String, val http: OkHttpClient) {

    fun url(path: String, query: Map<String, String?> = emptyMap()): HttpUrl {
        val b = baseUrl.newBuilder().addPathSegments("sdk/v1").addPathSegments(path)
        for ((k, v) in query) if (v != null) b.addQueryParameter(k, v)
        return b.build()
    }

    fun request(method: String, path: String, query: Map<String, String?> = emptyMap(), body: JSONObject? = null): Request {
        val rb = body?.toString()?.toRequestBody(JSON)
        return Request.Builder()
            .url(url(path, query))
            .header("X-Hive-Push-Key", key)
            .header("Accept", "application/json")
            .header("User-Agent", USER_AGENT)
            .method(method, rb)
            .build()
    }

    /** Sends a request and returns the body of a 2xx answer; other answers throw [HivePushException]. */
    suspend fun send(method: String, path: String, query: Map<String, String?> = emptyMap(), body: JSONObject? = null): String {
        val call = http.newCall(request(method, path, query, body))
        val response = call.await()
        response.use { r ->
            val text = try {
                r.body?.string() ?: ""
            } catch (e: IOException) {
                throw HivePushException("network", "Network error talking to Hive Push: ${e.message}", 0, e)
            }
            if (r.isSuccessful) return text
            throw error(r.code, text)
        }
    }

    companion object {
        val JSON = "application/json".toMediaType()
        val USER_AGENT = "HivePush-Android/${BuildConfig.SDK_VERSION}"

        /** Maps an error answer (`{"error": "...", "code": "..."}`) to a [HivePushException]. */
        fun error(status: Int, body: String?): HivePushException {
            val o = try {
                body?.takeIf { it.isNotBlank() }?.let { JSONObject(it) }
            } catch (_: Exception) {
                null
            }
            val code = o?.optStringOrNull("code") ?: "http_$status"
            val msg = o?.optStringOrNull("error") ?: "Hive Push request failed (HTTP $status)"
            return HivePushException(code, msg, status)
        }

        /** `https://push-<region>.dockhive.io`, or an explicit host. */
        fun baseUrl(region: String? = null, host: String? = null): HttpUrl {
            val h = host?.trim()?.trimEnd('/')
            if (!h.isNullOrEmpty()) {
                val full = if (h.startsWith("http://", true) || h.startsWith("https://", true)) h else "https://$h"
                return full.toHttpUrlOrNull()
                    ?: throw HivePushException("invalid_options", "Not a valid host: $host")
            }
            val r = region?.trim()
            if (!r.isNullOrEmpty()) {
                return "https://push-${r.lowercase()}.dockhive.io".toHttpUrlOrNull()
                    ?: throw HivePushException("invalid_options", "Not a valid region: $region")
            }
            throw HivePushException("invalid_options", "Pass a region (for example \"global-1\") or a host")
        }
    }
}

/** Runs the call without blocking, cancelling it when the coroutine is cancelled. */
internal suspend fun Call.await(): Response = suspendCancellableCoroutine { cont ->
    cont.invokeOnCancellation { runCatching { cancel() } }
    enqueue(object : Callback {
        override fun onResponse(call: Call, response: Response) {
            cont.resume(response) { _, value, _ -> value.close() }
        }

        override fun onFailure(call: Call, e: IOException) {
            if (!cont.isCancelled) {
                cont.resumeWithException(
                    HivePushException("network", "Network error talking to Hive Push: ${e.message}", 0, e),
                )
            }
        }
    })
}
