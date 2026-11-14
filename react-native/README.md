# @dockhive/push-react-native

Push notifications for React Native apps with [Hive Push](https://docs.dockhive.io/push/): reach
every install on iOS and Android, target signed-in users and tags, count opens, and show an in-app
inbox that updates live.

Notifications go out from **your** app's identity: your Apple Push Notification service (APNs) key
for iPhones and iPads, your Firebase project (FCM) for Android.

## Install

```sh
npm install @dockhive/push-react-native @react-native-firebase/app @react-native-firebase/messaging \
  @react-native-async-storage/async-storage
cd ios && pod install
```

The SDK uses `@react-native-firebase/messaging` to get the device's push token and AsyncStorage to
remember the device id. Set up React Native Firebase first (`google-services.json` on Android,
`GoogleService-Info.plist` on iOS).

## Quickstart

```ts
import HivePush from '@dockhive/push-react-native';

const push = HivePush.init({ key: 'pk_...', region: 'global-1' });
await push.requestPermission();
await push.register();                                // on every launch
await push.setUser('user-42', userTokenFromYourServer);
const { items, unread } = await push.inbox.list();    // newest first
const stop = push.inbox.onMessage((item) => console.log(item.title));
await push.inbox.markRead('all');
```

## Platform setup

Full guide: [docs.dockhive.io/push/](https://docs.dockhive.io/push/).

**iOS**

1. In the Hive Push console, open your app, go to **iOS (APNs)** and add your Apple key (`.p8`, key
   ID, team ID, bundle ID).
2. In Xcode, add the **Push Notifications** capability (and **Background Modes > Remote
   notifications** for background pushes).
3. Keep Firebase's app delegate proxy on (the default): the SDK reads the APNs token through it. On
   iOS, Firebase is only used to read that token; notifications reach the device through Apple with
   your key.
4. Development builds (`__DEV__`) register as `sandbox`, release builds as `production`. Override
   with `HivePush.init({ ..., environment: 'production' })`.

**Android**

1. In the console, go to **Android (FCM)** and upload your Firebase service account JSON.
2. On Android 13 and later, `requestPermission()` shows the system prompt. Make sure your
   `AndroidManifest.xml` has
   `<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />`.
3. Create a notification channel in your app if you send with `android.channel_id`.

## API

| Call | What it does |
| --- | --- |
| `HivePush.init({ key, region \| host, ... })` | Sets up the client (also `HivePush.instance()`). Options: `environment`, `appVersion`, `locale`, `timezone` (both default to the device's), `autoRegister`, `trackOpens`. |
| `push.requestPermission()` | Asks to show notifications; rejects with `permission_denied` when refused. |
| `push.register()` | Gets the APNs token (iOS) or FCM token (Android) and registers the install. Resolves `{ deviceId, created }`. Safe to call on every launch. |
| `push.setUser(userId, token)` | Attaches your signed-in user and enables the inbox. `token` is a user token made by your server with the app's secret key. |
| `push.setUser(null)` / `push.clearUser()` | Logs out: the install no longer belongs to a user. |
| `push.setTags({ plan: 'pro' })` | Replaces the install's tags (string values, at most 20 keys). |
| `push.unregister()` | Removes the install (for example when the user turns notifications off). |
| `push.reportOpened(remoteMessage)` / `push.reportOpenedData(data)` | Counts an open (`clicked`). |
| `push.reportEvent(notificationId, type)` | Reports `delivered`, `clicked` or `dismissed`. |
| `push.deviceId()` | This install's device id, kept across launches. |
| `push.inbox.list({ before, limit })` | `{ items, unread }`, newest first; `limit` up to 50; pass the last item's `id` as `before` for the next page. |
| `push.inbox.markRead(ids)` | Marks one id, an array of ids, or `'all'` as read. |
| `push.inbox.onMessage(cb, { onError, onConnect })` | Live inbox: calls `cb(item)` for every new item and reconnects on its own (1 s, doubling to 30 s). `onConnect` fires on each (re)connect: reload with `list()` to catch up. Returns `stop()`. |

User and tags set before `register()` are sent with the registration. If the push token changes, the
SDK registers again by itself.

### Counting opens

On Android, taps are counted automatically (`trackOpens: true`). On iOS, React Native Firebase
reports taps only for messages it sent itself, and Hive Push reaches iPhones directly through Apple,
so pass the tapped notification's `userInfo` to `push.reportOpenedData(userInfo)` from your tap
handler. The Hive Push notification id is in `hp_id` (Android) or `hp.id` (iOS);
`HivePush.notificationIdFrom(data)` reads either.

### Errors

Failures reject with `HivePushError` (`code`, `message`, HTTP `status`; 0 when the network failed).
Codes the SDK adds itself: `invalid_options`, `network`, `permission_denied`, `no_token`,
`not_registered`, `unsupported`. A common one is `platform_not_configured`: add your APNs key or
Firebase service account in the console first.

## License

MIT
