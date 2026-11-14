# Changelog

## 0.1.0 (2026-11-14)

First release of `io.dockhive:push`.

- `HivePush.init(context, key, region)` (or `initWithHost`) and a `HivePushClient` for apps that
  need several.
- `register(token)`, `registerWithFirebase()` and `registerInBackground(token)`; the device id is
  kept in `SharedPreferences` and a changed token replaces the old device.
- `setUser(userId, token)`, `clearUser()`, `setTags(tags)` and `unregister()`.
- `reportOpened(intent)` / `reportOpened(data)` and `report(type, notificationId)` for open /
  delivery / dismiss stats.
- Inbox: `list(before, limit)`, `markRead(ids)`, `markAllRead()`, and the live inbox as a
  `Flow<InboxItem>` that reconnects with backoff.
- `HivePushMessagingService`, an optional `FirebaseMessagingService` base that registers new
  tokens and reports deliveries.
- minSdk 23; depends on OkHttp and kotlinx-coroutines; Firebase Messaging comes from your app.
