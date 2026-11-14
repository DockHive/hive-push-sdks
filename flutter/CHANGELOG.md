# Changelog

## 0.1.0

First release.

- `HivePush.init(key:, region: | host:)` with optional `environment`, `appVersion`, `locale`, `timezone`.
- `requestPermission()` and `register()`: gets the APNs token on iOS and the FCM token on Android and
  registers the install; iOS uses `sandbox` in debug builds and `production` otherwise.
- Registers again by itself when the push token changes.
- `setUser(id, token)`, `clearUser()`, `setTags()`, `unregister()`.
- Open tracking: taps on notifications are reported as `clicked` (automatic on Android;
  `reportOpenedData(userInfo)` on iOS), plus `reportOpened(RemoteMessage)` and `reportEvent()`.
- In-app inbox: `inbox.list()`, `inbox.markRead()`, `inbox.markAllRead()`, and the live `inbox.messages`
  stream with automatic reconnect and `inbox.connection`.
- `package:hive_push/hive_push_api.dart`: the plain-Dart client, usable without Flutter or Firebase.
