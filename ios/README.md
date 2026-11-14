# HivePush for iOS

Native push notifications and an in-app inbox for your iOS app, with
[Hive Push](https://docs.dockhive.io/push/). Notifications are delivered by Apple (APNs) with
your own key, so they come from your app.

- iOS 14 and later, Swift 5.9 and later, no third-party dependencies
- async/await API; live inbox delivered on the main actor

## Install

**Xcode:** File > Add Package Dependencies, enter
`https://github.com/DockHive/hive-push-sdks`, and add the `HivePush` library to your app target.

**Package.swift:**

```swift
.package(url: "https://github.com/DockHive/hive-push-sdks", from: "0.1.0"),
// target dependency:
.product(name: "HivePush", package: "hive-push-sdks"),
```

Then, in your app target, turn on **Signing & Capabilities > + Capability > Push
Notifications** (and **Background Modes > Remote notifications** if you send data-only pushes).
Add your APNs key to the push app in the DockHive console first; until then registration
answers `platform_not_configured`.

## Quickstart

```swift
import HivePush
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    let pushDelegate = HivePushNotificationDelegate { url, _ in /* open url */ }

    func application(_ app: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        HivePush.configure(key: "pk_your_public_key", region: "global-1")
        UNUserNotificationCenter.current().delegate = pushDelegate
        Task { try? await HivePush.requestAuthorization() }   // then iOS calls the method below
        return true
    }

    func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        Task { try? await HivePush.shared.register(deviceToken: token) }
    }
}
```

After sign-in, attach the user with a user token made by your server (never put the secret
key in the app):

```swift
try await HivePush.shared.setUser(id: "user-42", token: userTokenFromYourServer)
```

## API

| Call | What it does |
| --- | --- |
| `HivePush.configure(key:region:)` / `configure(key:host:)` | Sets up `HivePush.shared` with the app's public key and region (or host) from the console. |
| `register(deviceToken:environment:)` | Registers this install. Call it on every launch from `didRegisterForRemoteNotificationsWithDeviceToken`. `environment`: `.auto` (default: sandbox in DEBUG builds, production otherwise), `.sandbox` or `.production`. Returns the device id. |
| `setUser(id:token:)` | Attaches your signed-in user (before or after `register`) and enables the inbox. |
| `clearUser()` | Signs the user out of this install; live inbox streams stop. |
| `setTags(_:)` | Replaces this install's tags, for example `["plan": "pro"]` (at most 20). |
| `unregister()` | Removes this install (the user turned notifications off). |
| `reportOpened(userInfo:)` | Reports a tap on a notification so it counts in your stats. `HivePushNotificationDelegate` does this for you. |
| `report(_:notificationId:)` | Reports `.delivered`, `.clicked` or `.dismissed` yourself (for example from a notification service extension). |
| `deviceId`, `userId` | This install's device id (kept in `UserDefaults`) and the current user. |
| `HivePush.url(from:)`, `data(from:)`, `notificationId(from:)` | Read `hp.url`, `hp.data` and `hp.id` from a notification's `userInfo`. |
| `inbox.list(before:limit:)` | The user's inbox, newest first (`limit` up to 50). Pass the last item's `id` as `before` for the next page. |
| `inbox.markRead(_:)`, `inbox.markAllRead()` | Marks items as read. |
| `inbox.onMessage(_:onError:)` | Live inbox: calls you on the main actor for every new item. Reconnects on its own (1 s, doubling to 30 s). Returns a subscription to `cancel()`. |
| `inbox.messages()` | The same as an `AsyncStream<InboxItem>`. |

Errors are thrown as `HivePushError` with `code` (the API's error code, such as
`platform_not_configured` or `invalid_user_token`, or `network`), `message` and HTTP `status`.

### Sandbox and production tokens

Builds installed from Xcode get **sandbox** device tokens; TestFlight and App Store builds get
**production** tokens. `.auto` picks sandbox when the package is compiled with `DEBUG` (Xcode's
Debug configuration) and production otherwise. If you ship Debug-configured builds through
TestFlight, pass the environment explicitly.

### Notification payload

What your app receives:

```json
{"aps": {"alert": {"title": "Your order shipped", "body": "It arrives on Thursday."}},
 "hp": {"id": "ntf_...", "url": "https://shop.example/orders/77", "data": {"order_id": 77},
        "image": "https://shop.example/box.png"}}
```

`hp.image` is there for a notification service extension that downloads and attaches it (send
with `"ios": {"mutable_content": true}`).

## Development

```sh
cd ios
swift test
```

The package also builds on macOS so the tests run on a Mac host; push registration helpers are
iOS-only.

## License

MIT, see [LICENSE](LICENSE).
