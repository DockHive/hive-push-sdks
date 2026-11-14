package io.dockhive.push

import android.content.Context
import android.content.Intent
import android.util.Log
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Hive Push for Android apps.
 *
 * ```kotlin
 * // Application.onCreate
 * HivePush.init(this, key = "pk_...", region = "global-1")
 * lifecycleScope.launch { HivePush.registerWithFirebase() }
 * ```
 */
object HivePush {
    const val VERSION: String = BuildConfig.SDK_VERSION

    /** Data key with the Hive Push notification id. */
    const val KEY_ID = "hp_id"

    /** Data key with the notification's link. */
    const val KEY_URL = "hp_url"

    private const val TAG = "HivePush"

    @Volatile
    private var instance: HivePushClient? = null

    /** Background work started by the SDK itself (token refreshes). */
    internal val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /**
     * Sets up Hive Push with the app's public key (`pk_...`) and region (for example
     * `global-1`), as shown on the app's page in the console. Call it in
     * `Application.onCreate`, before anything else uses Hive Push.
     */
    @JvmStatic
    fun init(context: Context, key: String, region: String): HivePushClient =
        HivePushClient(context.applicationContext, key, region = region).also { instance = it }

    /** Like [init], with an explicit host (for example `push-global-1.dockhive.io`). */
    @JvmStatic
    fun initWithHost(context: Context, key: String, host: String): HivePushClient =
        HivePushClient(context.applicationContext, key, host = host).also { instance = it }

    /** The client set up by [init]. */
    @JvmStatic
    val client: HivePushClient
        get() = instance ?: throw HivePushException("not_initialized", "Call HivePush.init(context, key, region) in Application.onCreate first")

    /** Whether [init] was called. */
    @JvmStatic
    val isInitialized: Boolean get() = instance != null

    /** The in-app inbox of the signed-in user. */
    val inbox: Inbox get() = client.inbox

    /** This install's device id, or null until registered. */
    val deviceId: String? get() = client.deviceId

    /** The user set with [setUser], or null. */
    val userId: String? get() = client.userId

    /** Registers this install's FCM registration token; see [HivePushClient.register]. */
    suspend fun register(token: String): String = client.register(token)

    /**
     * Gets the FCM registration token from Firebase Messaging and registers it. Needs the
     * `com.google.firebase:firebase-messaging` dependency in your app. Call it on every start.
     */
    @Suppress("DEPRECATION") // getToken() still works on firebase-messaging 25.x
    suspend fun registerWithFirebase(): String {
        val token = suspendCancellableCoroutine<String> { cont ->
            FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                if (task.isSuccessful && task.result != null) {
                    cont.resume(task.result)
                } else {
                    cont.resumeWithException(
                        HivePushException("network", "Could not get the FCM token: ${task.exception?.message}", 0, task.exception),
                    )
                }
            }
        }
        return client.register(token)
    }

    /**
     * Registers a token without waiting, for `FirebaseMessagingService.onNewToken`. Errors are
     * logged; the next start registers again.
     */
    @JvmStatic
    fun registerInBackground(token: String) {
        val c = instance
        if (c == null) {
            Log.w(TAG, "onNewToken before HivePush.init: call HivePush.init in Application.onCreate")
            return
        }
        scope.launch {
            try {
                c.register(token)
            } catch (e: HivePushException) {
                Log.w(TAG, "Registering the push token failed: ${e.code}: ${e.message}")
            }
        }
    }

    /** Attaches your signed-in user; see [HivePushClient.setUser]. */
    suspend fun setUser(userId: String, token: String) = client.setUser(userId, token)

    /** Signs the user out of this install. */
    suspend fun clearUser() = client.clearUser()

    /** Replaces this install's tags. */
    suspend fun setTags(tags: Map<String, String>) = client.setTags(tags)

    /** Removes this install from Hive Push. */
    suspend fun unregister() = client.unregister()

    /** Reports a notification open from the `RemoteMessage` data. */
    suspend fun reportOpened(data: Map<String, String?>): Boolean = client.reportOpened(data)

    /** Reports a notification open from the intent that started your activity. */
    suspend fun reportOpened(intent: Intent?): Boolean = client.reportOpened(intent)

    /** Reports a delivered, clicked or dismissed event. */
    suspend fun report(type: HivePushEvent, notificationId: String): Boolean = client.report(type, notificationId)

    /** The Hive Push notification id in a message's data, or null when it is not from Hive Push. */
    @JvmStatic
    fun notificationId(data: Map<String, String?>): String? = data[KEY_ID]?.takeIf { it.isNotEmpty() }

    /** The notification's link (`hp_url`), if it has one. */
    @JvmStatic
    fun url(data: Map<String, String?>): String? = data[KEY_URL]?.takeIf { it.isNotEmpty() }

    /** Whether a message's data is from Hive Push. */
    @JvmStatic
    fun isHivePushMessage(data: Map<String, String?>): Boolean = notificationId(data) != null
}
