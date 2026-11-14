# hive_push

Push notifications for Flutter apps with [Hive Push](https://docs.dockhive.io/push/): reach every
install on iOS and Android, target signed-in users and tags, count opens, and show an in-app inbox
that updates live.

Notifications go out from **your** app's identity: your Apple Push Notification service (APNs) key
for iPhones and iPads, your Firebase project (FCM) for Android.

## Install

```yaml
dependencies:
  hive_push: ^0.1.0
  firebase_core: ^4.0.0
```

The SDK uses `firebase_messaging` to get the device's push token, so add Firebase to your app first
(`flutterfire configure`).

## Quickstart

```dart
import 'package:firebase_core/firebase_core.dart';
import 'package:hive_push/hive_push.dart';

await Firebase.initializeApp();
final push = await HivePush.init(key: 'pk_...', region: 'global-1');
await push.requestPermission();
await push.register();                              // on every launch
await push.setUser('user-42', userTokenFromYourServer);
final page = await push.inbox.list();               // newest first
push.inbox.messages.listen((item) => print(item.title));
```

## Platform setup

Full guide: [docs.dockhive.io/push/](https://docs.dockhive.io/push/).

**iOS**

1. In the Hive Push console, open your app, go to **iOS (APNs)** and add your Apple key (`.p8`, key
   ID, team ID, bundle ID).
2. In Xcode, add the **Push Notifications** capability to the Runner target (and **Background Modes >
   Remote notifications** for background pushes).
3. Keep Firebase's app delegate proxy on (the default): the SDK reads the APNs token through it. On
   iOS, Firebase is only used to read that token; notifications reach the device through Apple with
   your key.
4. Debug builds register as `sandbox`, release builds as `production`. Override with
   `HivePush.init(..., environment: ApnsEnvironment.production)`, for example for a profile build
   distributed through TestFlight.

To show notifications while the app is in the foreground:

```dart
await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(alert: true, badge: true, sound: true);
```

**Android**

1. In the console, go to **Android (FCM)** and upload your Firebase service account JSON.
2. On Android 13 and later, `requestPermission()` shows the system prompt.
3. Create a notification channel in your app if you send with `android.channel_id`.

## API

| Call | What it does |
| --- | --- |
| `HivePush.init(key:, region: \| host:, ...)` | Sets up the client (also `HivePush.instance`). Options: `environment`, `appVersion`, `locale` (defaults to the device language), `timezone` (IANA, e.g. `Africa/Lagos`), `autoRegister`, `trackOpens`. |
| `requestPermission()` | Asks to show notifications; throws `permission_denied` when refused. |
| `register()` | Gets the APNs token (iOS) or FCM token (Android) and registers the install. Returns `Registration(deviceId, created)`. Safe to call on every launch. |
| `setUser(userId, token)` | Attaches your signed-in user and enables the inbox. `token` is a user token made by your server with the app's secret key. |
| `clearUser()` | Logs out: the install keeps its tags and pushes to everyone, but no longer belongs to a user. |
| `setTags({'plan': 'pro'})` | Replaces the install's tags (string values, at most 20 keys). |
| `unregister()` | Removes the install (for example when the user turns notifications off). |
| `reportOpened(RemoteMessage)` / `reportOpenedData(data)` | Counts an open (`clicked`). |
| `reportEvent(notificationId, type)` | Reports `delivered`, `clicked` or `dismissed`. |
| `deviceId` | This install's device id, kept across launches. |
| `inbox.list(before:, limit:)` | `InboxPage(items, unread)`, newest first; `limit` up to 50; pass the last item's `id` as `before` for the next page. |
| `inbox.markRead(ids)` / `inbox.markAllRead()` | Marks items as read. |
| `inbox.messages` | A stream of new inbox items, live. Connects while listened to and reconnects on its own (1 s, doubling to 30 s). |
| `inbox.connection` | `true` when the live connection opens, `false` when it drops; reload with `inbox.list()` on `true` to catch up. |

User and tags set before `register()` are sent with the registration. If the push token changes,
the SDK registers again by itself.

### Counting opens

On Android, taps are counted automatically (`trackOpens: true`). On iOS, Firebase reports taps only
for messages it sent itself, and Hive Push reaches iPhones directly through Apple, so pass the tapped
notification's `userInfo` to `push.reportOpenedData(userInfo)` from your tap handler. The Hive Push
notification id is in `hp_id` (Android) or `hp.id` (iOS); `HivePush.notificationIdFrom(data)` reads
either.

### Errors

Failures throw `HivePushException` with a stable `code`, a readable `message` and the HTTP `status`
(0 when the network failed). Codes the SDK adds itself: `invalid_options`, `network`,
`permission_denied`, `no_token`, `not_registered`, `unsupported`. A common one is
`platform_not_configured`: add your APNs key or Firebase service account in the console first.

### Without Flutter

`package:hive_push/hive_push_api.dart` is the plain-Dart client (`HivePushApi`, `InboxStream`)
with no Flutter or Firebase imports, for apps that get push tokens another way.

## License

MIT
