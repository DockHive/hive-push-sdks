# Hive Push for Android

Native push notifications and an in-app inbox for your Android app, with
[Hive Push](https://docs.dockhive.io/push/). Notifications are delivered by Firebase Cloud
Messaging (FCM) with your own Firebase project, so they come from your app.

- minSdk 23, Kotlin coroutines API (`suspend` functions and `Flow`)
- Depends on OkHttp and kotlinx-coroutines; Firebase Messaging comes from your app

## Install

Add your Firebase service account to the push app in the DockHive console first; until then
registration answers `platform_not_configured`. Then set up Firebase in the app (download
`google-services.json` from the Firebase console into `app/`) and add:

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven("https://docs.dockhive.io/maven")
    }
}

// build.gradle.kts (project)
plugins {
    id("com.google.gms.google-services") version "4.4.2" apply false
}

// app/build.gradle.kts
plugins {
    id("com.google.gms.google-services")
}
dependencies {
    implementation("io.dockhive:push:0.1.0")
    implementation("com.google.firebase:firebase-messaging:25.1.0")
}
```

On Android 13 and later, ask for the `POST_NOTIFICATIONS` runtime permission before expecting
notifications to show (declare it in your manifest too).

## Quickstart

```kotlin
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        HivePush.init(this, key = "pk_your_public_key", region = "global-1")
        ProcessLifecycleOwner.get().lifecycleScope.launch {
            runCatching { HivePush.registerWithFirebase() }   // every start; tokens can change
        }
    }
}

class PushService : HivePushMessagingService()   // registers new tokens; declare it in the manifest
```

```xml
<service android:name=".PushService" android:exported="false">
    <intent-filter><action android:name="com.google.firebase.MESSAGING_EVENT" /></intent-filter>
</service>
```

After sign-in, attach the user with a user token made by your server (never put the secret key
in the app):

```kotlin
HivePush.setUser("user-42", userTokenFromYourServer)
```

When the user taps a notification, Android opens your launcher activity with the message data
in the intent extras. Report the open there:

```kotlin
override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    lifecycleScope.launch { runCatching { HivePush.reportOpened(intent) } }
    // intent.getStringExtra(HivePush.KEY_URL) is the notification's link, if any
}
```

## API

| Call | What it does |
| --- | --- |
| `HivePush.init(context, key, region)` / `initWithHost(context, key, host)` | Sets up Hive Push with the app's public key and region (or host) from the console. Call it in `Application.onCreate`. |
| `register(token)` | Registers an FCM registration token. Returns the device id. |
| `registerWithFirebase()` | Gets the token from Firebase Messaging and registers it. Call it on every start. |
| `registerInBackground(token)` | Fire-and-forget registration, for your own `onNewToken`. |
| `setUser(userId, token)` | Attaches your signed-in user (before or after registering) and enables the inbox. |
| `clearUser()` | Signs the user out of this install; live inbox streams end. |
| `setTags(mapOf("plan" to "pro"))` | Replaces this install's tags (at most 20). |
| `unregister()` | Removes this install (the user turned notifications off). |
| `reportOpened(intent)` / `reportOpened(data)` | Reports a tap on a notification so it counts in your stats. |
| `report(HivePushEvent.DELIVERED, notificationId)` | Reports `DELIVERED`, `CLICKED` or `DISMISSED` yourself. |
| `deviceId`, `userId` | This install's device id (kept in `SharedPreferences`) and the current user. |
| `HivePush.notificationId(data)`, `url(data)`, `isHivePushMessage(data)` | Read `hp_id` and `hp_url` from a message's data. |
| `inbox.list(before, limit)` | The user's inbox, newest first (`limit` up to 50). Pass the last item's `id` as `before` for the next page. |
| `inbox.markRead(ids)`, `inbox.markAllRead()` | Marks items as read. |
| `inbox.stream()` | The live inbox as a `Flow<InboxItem>`. Reconnects on its own (1 s, doubling to 30 s); fails with `HivePushException` when the user token expires. Collect it in `lifecycleScope` to get items on the main thread. |

All of these are `suspend` functions on `HivePush` (and on `HivePushClient`, if you create one
yourself). Errors are thrown as `HivePushException` with `code` (the API's error code, such as
`platform_not_configured` or `invalid_user_token`, or `network`), `message` and HTTP `status`.

### Message data

A Hive Push message carries the notification's `title`, `body` and `image` in its notification
part (shown by the system while your app is in the background), and in its data: `hp_id`,
`hp_url`, and each key of the `data` object you sent as a string (other values as JSON).

`HivePushMessagingService` reports `delivered` for Hive Push messages that reach
`onMessageReceived` (data-only pushes, and any message while your app is in the foreground).
Override `onMessageReceived` to handle them, and call `super`.

## Development

```sh
cd android
./gradlew test
```

Needs JDK 17 and the Android SDK (`ANDROID_HOME` or `local.properties`).

## License

MIT, see [LICENSE](LICENSE).
