package io.dockhive.push

import android.content.Context
import android.content.Intent
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * A Hive Push client for one app. Most apps use the [HivePush] singleton instead; create a
 * client yourself only to talk to several Hive Push apps or to pass your own [OkHttpClient].
 */
class HivePushClient internal constructor(
    key: String,
    baseUrl: HttpUrl,
    private val store: DeviceStore,
    http: OkHttpClient,
    private val deviceInfo: () -> DeviceInfo,
) {
    /**
     * @param key the app's public key (`pk_...`), never the secret key.
     * @param region the app's region (for example `global-1`); or pass [host].
     */
    @JvmOverloads
    constructor(
        context: Context,
        key: String,
        region: String? = null,
        host: String? = null,
        http: OkHttpClient = defaultHttp,
    ) : this(
        key,
        Transport.baseUrl(region, host),
        PrefsDeviceStore(context, key),
        http,
        { DeviceInfo.current(context.applicationContext) },
    )

    init {
        if (!key.startsWith("pk_")) {
            throw HivePushException("invalid_options", "Use the app's public key (pk_...), never the secret key")
        }
    }

    internal val transport = Transport(baseUrl, key, http)
    private val lock = Any()
    private var userToken: String? = null
    private var currentUserId: String? = null
    private var pendingTags: Map<String, String>? = null

    /** The in-app inbox of the signed-in user (after [setUser]). */
    val inbox = Inbox(transport) { synchronized(lock) { userToken } }

    /** This install's device id (`dev_...`), kept across launches; null until registered. */
    val deviceId: String? get() = store.deviceId

    /** The user set with [setUser], or null. */
    val userId: String? get() = synchronized(lock) { currentUserId }

    /**
     * Registers this install's FCM registration token. Call it on every start (with
     * `FirebaseMessaging.getInstance().token`) and from `FirebaseMessagingService.onNewToken`:
     * registering the same token again just refreshes it, and a new token replaces the old device.
     *
     * @return the device id.
     */
    suspend fun register(token: String): String {
        val body = JSONObject().put("platform", "android").put("token", token)
        for ((k, v) in deviceInfo().fields()) body.put(k, v)
        synchronized(lock) {
            userToken?.let { body.put("user_token", it) }
            pendingTags?.let { body.put("tags", JSONObject(it)) }
        }
        val text = transport.send("POST", "devices", body = body)
        val id = try {
            JSONObject(text).getString("device_id")
        } catch (e: Exception) {
            throw HivePushException("invalid_response", "Registration answered without a device_id", 0, e)
        }
        val previous = store.deviceId
        store.deviceId = id
        store.token = token
        if (previous != null && previous != id) {
            // The token changed: the old device can no longer receive anything.
            runCatching { transport.send("DELETE", "devices/$previous") }
        }
        return id
    }

    /** PATCHes this device; before registration the change is sent with the registration. */
    private suspend fun patchDevice(body: JSONObject) {
        val id = store.deviceId ?: return
        try {
            transport.send("PATCH", "devices/$id", body = body)
        } catch (e: HivePushException) {
            if (e.status != 404) throw e
            // The device was removed on the server (for example the user's data was deleted):
            // register again with the current user and tags.
            store.deviceId = null
            store.token?.let { register(it) }
        }
    }

    /**
     * Attaches your signed-in user to this install and enables the inbox. [token] is a user token
     * made by your server with the app's secret key. Can be called before or after [register].
     */
    suspend fun setUser(userId: String, token: String) {
        if (token.isEmpty()) throw HivePushException("invalid_user_token", "setUser needs the user token from your server")
        val changed = synchronized(lock) {
            val c = currentUserId != null && currentUserId != userId
            currentUserId = userId
            userToken = token
            c
        }
        if (changed) inbox.stopAll()
        patchDevice(JSONObject().put("user_token", token))
    }

    /** Signs the user out: the install keeps app-wide notifications; live inbox streams end. */
    suspend fun clearUser() {
        synchronized(lock) {
            currentUserId = null
            userToken = null
        }
        inbox.stopAll()
        patchDevice(JSONObject().put("user_id", JSONObject.NULL))
    }

    /** Replaces this install's tags (string values, at most 20 keys). */
    suspend fun setTags(tags: Map<String, String>) {
        synchronized(lock) { pendingTags = tags.toMap() }
        patchDevice(JSONObject().put("tags", JSONObject(tags)))
    }

    /** Removes this install from Hive Push (the user turned notifications off). */
    suspend fun unregister() {
        val id = store.deviceId ?: return
        store.deviceId = null
        store.token = null
        try {
            transport.send("DELETE", "devices/$id")
        } catch (e: HivePushException) {
            if (e.status != 404) throw e
        }
    }

    /**
     * Reports that the user opened a notification, from the data of the `RemoteMessage` or the
     * extras of the launch intent (`hp_id`).
     *
     * @return false when it is not a Hive Push notification or the install is not registered.
     */
    suspend fun reportOpened(data: Map<String, String?>): Boolean {
        val nid = HivePush.notificationId(data) ?: return false
        return report(HivePushEvent.CLICKED, nid)
    }

    /** Reports an open from the intent that started your activity from a notification tap. */
    suspend fun reportOpened(intent: Intent?): Boolean {
        val nid = intent?.extras?.getString(HivePush.KEY_ID) ?: return false
        return report(HivePushEvent.CLICKED, nid)
    }

    /** Reports a delivered, clicked or dismissed event for a notification. */
    suspend fun report(type: HivePushEvent, notificationId: String): Boolean {
        val id = store.deviceId ?: return false
        transport.send(
            "POST", "events",
            body = JSONObject().put("device_id", id).put("notification_id", notificationId).put("type", type.wire),
        )
        return true
    }

    companion object {
        internal val defaultHttp: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(15, TimeUnit.SECONDS)
                .readTimeout(30, TimeUnit.SECONDS)
                .build()
        }
    }
}
