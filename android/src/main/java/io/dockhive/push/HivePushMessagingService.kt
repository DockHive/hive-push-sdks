package io.dockhive.push

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlinx.coroutines.launch

/**
 * An optional base for your `FirebaseMessagingService`: registers every new FCM token with
 * Hive Push and reports `delivered` for Hive Push messages that reach your app. Override
 * [onMessageReceived] to handle data-only pushes or show notifications while your app is open
 * (call `super`).
 *
 * ```xml
 * <service android:name=".PushService" android:exported="false">
 *     <intent-filter><action android:name="com.google.firebase.MESSAGING_EVENT" /></intent-filter>
 * </service>
 * ```
 *
 * Needs `com.google.firebase:firebase-messaging` in your app, and `HivePush.init` in
 * `Application.onCreate`.
 */
open class HivePushMessagingService : FirebaseMessagingService() {

    @Deprecated("Firebase Messaging 25 also reports tokens with onRegistered; both are handled.")
    @Suppress("DEPRECATION")
    override fun onNewToken(token: String) {
        super.onNewToken(token)
        HivePush.registerInBackground(token)
    }

    /** Firebase Messaging 25 and later. Registering the same token twice is harmless. */
    override fun onRegistered(token: String) {
        super.onRegistered(token)
        HivePush.registerInBackground(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)
        val nid = HivePush.notificationId(message.data) ?: return
        if (!HivePush.isInitialized) return
        val client = HivePush.client
        HivePush.scope.launch {
            runCatching { client.report(HivePushEvent.DELIVERED, nid) }
        }
    }
}
