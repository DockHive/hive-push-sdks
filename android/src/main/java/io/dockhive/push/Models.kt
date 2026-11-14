package io.dockhive.push

import org.json.JSONArray
import org.json.JSONObject

/**
 * An error from Hive Push or from the SDK itself.
 *
 * [code] is the stable error code from the API (for example `platform_not_configured`,
 * `invalid_user_token`, `rate_limited`) or one the SDK adds: `network`, `invalid_options`,
 * `invalid_response`, `not_initialized`. [status] is the HTTP status, or 0 when no answer was
 * received.
 */
class HivePushException(
    val code: String,
    message: String,
    val status: Int = 0,
    cause: Throwable? = null,
) : Exception(message, cause) {
    override fun toString(): String = "HivePushException($code, status $status): $message"
}

/** The type of a notification event reported to Hive Push. */
enum class HivePushEvent(val wire: String) {
    DELIVERED("delivered"),
    CLICKED("clicked"),
    DISMISSED("dismissed"),
}

/** A button on a notification. */
data class InboxAction(val action: String, val title: String, val url: String?)

/** One item of a user's in-app inbox. */
data class InboxItem(
    val id: String,
    val notificationId: String,
    /** RFC 3339 time the item was created. */
    val createdAt: String,
    /** RFC 3339 time the item was read, or null while unread. */
    val readAt: String?,
    val title: String,
    val body: String?,
    val url: String?,
    val icon: String?,
    val image: String?,
    /** The notification's `data` object (nested objects as maps, arrays as lists). */
    val data: Map<String, Any?>,
    val actions: List<InboxAction>,
    /** The item as JSON, for fields this version of the SDK does not model. */
    val raw: String,
) {
    val isRead: Boolean get() = readAt != null

    companion object {
        internal fun fromJson(o: JSONObject): InboxItem = InboxItem(
            id = o.getString("id"),
            notificationId = o.optStringOrNull("notification_id") ?: "",
            createdAt = o.optStringOrNull("created_at") ?: "",
            readAt = o.optStringOrNull("read_at"),
            title = o.optStringOrNull("title") ?: "",
            body = o.optStringOrNull("body"),
            url = o.optStringOrNull("url"),
            icon = o.optStringOrNull("icon"),
            image = o.optStringOrNull("image"),
            data = o.optJSONObject("data")?.toMap() ?: emptyMap(),
            actions = o.optJSONArray("actions")?.let { arr ->
                (0 until arr.length()).mapNotNull { i ->
                    arr.optJSONObject(i)?.let { a ->
                        InboxAction(a.optStringOrNull("action") ?: "", a.optStringOrNull("title") ?: "", a.optStringOrNull("url"))
                    }
                }
            } ?: emptyList(),
            raw = o.toString(),
        )
    }
}

/** A page of the inbox, newest first, with the user's total number of unread items. */
data class InboxPage(val items: List<InboxItem>, val unread: Int)

internal fun JSONObject.optStringOrNull(key: String): String? =
    if (!has(key) || isNull(key)) null else opt(key)?.toString()

internal fun JSONObject.toMap(): Map<String, Any?> {
    val out = LinkedHashMap<String, Any?>()
    val it = keys()
    while (it.hasNext()) {
        val k = it.next()
        out[k] = unwrapJson(opt(k))
    }
    return out
}

private fun unwrapJson(v: Any?): Any? = when (v) {
    null, JSONObject.NULL -> null
    is JSONObject -> v.toMap()
    is JSONArray -> (0 until v.length()).map { unwrapJson(v.opt(it)) }
    else -> v
}
