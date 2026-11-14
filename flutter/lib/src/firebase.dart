import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';

import 'models.dart';
import 'platform.dart';

/// [PushMessaging] backed by Firebase Messaging: the FCM token on Android and
/// the APNs device token (`getAPNSToken()`) on iOS.
class FirebasePushMessaging implements PushMessaging {
  FirebasePushMessaging({FirebaseMessaging? messaging, this.apnsTokenWait = const Duration(seconds: 5)})
      : _m = messaging ?? FirebaseMessaging.instance;

  final FirebaseMessaging _m;

  /// How long to wait for iOS to hand over the APNs token after launch.
  final Duration apnsTokenWait;

  @override
  Future<bool> requestPermission() async {
    final s = await _m.requestPermission();
    return s.authorizationStatus == AuthorizationStatus.authorized ||
        s.authorizationStatus == AuthorizationStatus.provisional;
  }

  @override
  Future<String?> getToken(PushPlatform platform) async {
    if (platform == PushPlatform.android) return _m.getToken();
    // iOS hands the APNs token over shortly after registering for remote
    // notifications; poll briefly instead of failing on the first launch.
    final deadline = DateTime.now().add(apnsTokenWait);
    while (true) {
      final t = await _m.getAPNSToken();
      if (t != null && t.isNotEmpty) return t;
      if (DateTime.now().isAfter(deadline)) return null;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  @override
  Stream<void> get onTokenRefresh => _m.onTokenRefresh.map((_) {});

  @override
  Stream<Map<String, dynamic>> get onNotificationOpened => FirebaseMessaging.onMessageOpenedApp.map((m) => m.data);

  @override
  Future<Map<String, dynamic>?> getInitialNotification() async => (await _m.getInitialMessage())?.data;
}
