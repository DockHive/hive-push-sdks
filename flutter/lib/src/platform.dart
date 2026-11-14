import 'dart:async';

import 'models.dart';

/// Where the SDK keeps the device id between launches.
abstract class HivePushStorage {
  Future<String?> read(String key);

  /// Writes [value], or removes the key when it is null.
  Future<void> write(String key, String? value);
}

/// Keeps values in memory only (tests, or apps that do their own persistence).
class MemoryHivePushStorage implements HivePushStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

/// What the SDK needs from the operating system's push service. The default
/// uses Firebase Messaging; pass your own to [HivePush.init] for tests or a
/// custom setup.
abstract class PushMessaging {
  /// Asks the user for permission to show notifications. True when granted
  /// (including iOS provisional authorization).
  Future<bool> requestPermission();

  /// The push token for [platform]: the APNs device token as hex on iOS, the
  /// FCM registration token on Android. Null when it is not available yet.
  Future<String?> getToken(PushPlatform platform);

  /// Fires when the operating system issues a new token.
  Stream<void> get onTokenRefresh;

  /// The data of each notification the user taps while the app is running
  /// or in the background.
  Stream<Map<String, dynamic>> get onNotificationOpened;

  /// The data of the notification that launched the app, if any.
  Future<Map<String, dynamic>?> getInitialNotification();
}
