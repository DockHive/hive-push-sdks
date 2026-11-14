# Changelog

## 0.1.0 (2026-11-14)

First release of the Hive Push Swift package.

- `HivePush.configure(key:region:)` / `configure(key:host:)` and `HivePush.shared`.
- `register(deviceToken:environment:)` with `.auto` (sandbox in DEBUG builds, production
  otherwise), `.sandbox` and `.production`; the device id is kept across launches and a
  changed token replaces the old device.
- `setUser(id:token:)`, `clearUser()`, `setTags(_:)` and `unregister()`.
- `reportOpened(userInfo:)` and `report(_:notificationId:)` for open / delivery / dismiss stats.
- Inbox: `list(before:limit:)`, `markRead(_:)`, `markAllRead()`, and the live inbox with
  `onMessage(_:onError:)` (main actor) or `messages()` (`AsyncStream`), reconnecting with backoff.
- `HivePushNotificationDelegate` and `HivePush.requestAuthorization()` helpers.
- iOS 14 and later, no third-party dependencies.
