# Changelog

## 0.1.0

First release.

- `HivePush.init({ key, region | host })` with optional `environment`, `appVersion`, `locale`, `timezone`
  (locale and time zone default to the device's).
- `requestPermission()` (including the Android 13+ notification permission) and `register()`: gets the
  APNs token on iOS and the FCM token on Android through `@react-native-firebase/messaging` and registers
  the install; iOS uses `sandbox` in development (`__DEV__`) and `production` otherwise.
- Registers again by itself when the push token changes.
- `setUser(id, token)`, `setUser(null)` / `clearUser()`, `setTags()`, `unregister()`, `deviceId()`.
- Open tracking: taps are reported as `clicked` (automatic on Android; `reportOpenedData(userInfo)` on
  iOS), plus `reportOpened(remoteMessage)` and `reportEvent()`.
- In-app inbox: `inbox.list()`, `inbox.markRead(ids | 'all')`, and the live `inbox.onMessage(cb)` with
  automatic reconnect (streams over XMLHttpRequest, since React Native's `fetch` cannot stream).
- `HivePushApi`: the plain HTTP client, usable on its own.
