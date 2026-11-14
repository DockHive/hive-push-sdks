# Hive Push SDKs

Client SDKs for [Hive Push](https://docs.dockhive.io/push/) native and cross-platform apps.

| Package | Path | Platform |
| --- | --- | --- |
| `hive_push` (Flutter) | `flutter/` | iOS + Android |
| `@dockhive/push-react-native` | `react-native/` | iOS + Android |
| `HivePush` (Swift Package) | `ios/` | iOS |
| `io.dockhive:push` (Kotlin) | `android/` | Android |

All of them do the same small job: get the operating system's push token, register it with
Hive Push (`POST /sdk/v1/devices`), keep the user and tags in sync, report opens, and expose the
in-app inbox. The API they call is documented in the service repo (`DockHive/hive-push`,
`docs/API.md`).
