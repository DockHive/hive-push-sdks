import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart' show RemoteMessage;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'errors.dart';
import 'firebase.dart';
import 'models.dart';
import 'platform.dart';
import 'sse.dart';

final _localeRE = RegExp(r'^[A-Za-z]{2,3}([-_][A-Za-z0-9]{1,8}){0,4}$');

/// Hive Push for Flutter apps: registers the install for iOS / Android push,
/// keeps its user and tags in sync, reports opens and gives you the in-app
/// inbox.
///
/// ```dart
/// final push = await HivePush.init(key: 'pk_...', region: 'global-1');
/// await push.requestPermission();
/// await push.register();
/// ```
class HivePush {
  /// Builds a client from its parts. Use [HivePush.init] in apps; this is for
  /// tests and custom setups.
  HivePush.withDependencies({
    required this.api,
    required PushMessaging messaging,
    required HivePushStorage storage,
    required this.platform,
    this.environment,
    this.appVersion,
    this.locale,
    this.timezone,
    String? deviceId,
  })  : _messaging = messaging,
        _storage = storage,
        _deviceId = deviceId {
    inbox = HivePushInbox._(this);
  }

  static HivePush? _instance;

  /// The client made by the last [init] call.
  static HivePush get instance {
    final i = _instance;
    if (i == null) {
      throw HivePushException('Call HivePush.init(...) first', code: 'invalid_options');
    }
    return i;
  }

  /// Sets up Hive Push. Call it once at startup, after `Firebase.initializeApp()`.
  ///
  /// - [key]: the app's public key (`pk_...`).
  /// - [region] (for example `global-1`) or [host].
  /// - [environment]: the iOS push environment; defaults to `sandbox` in debug
  ///   builds and `production` otherwise.
  /// - [appVersion], [locale] (defaults to the device language), [timezone]
  ///   (an IANA name such as `Africa/Lagos`): optional install details.
  /// - [autoRegister]: re-register by itself when the push token changes.
  /// - [trackOpens]: report taps on notifications as `clicked` events.
  static Future<HivePush> init({
    required String key,
    String? region,
    String? host,
    ApnsEnvironment? environment,
    String? appVersion,
    String? locale,
    String? timezone,
    bool autoRegister = true,
    bool trackOpens = true,
    http.Client? httpClient,
    PushMessaging? messaging,
    HivePushStorage? storage,
    PushPlatform? platform,
  }) async {
    final api = HivePushApi(key: key, region: region, host: host, client: httpClient);
    final plat = platform ?? _currentPlatform();
    final store = storage ?? _PrefsStorage();
    final deviceId = await store.read(_deviceKey(key));
    final push = HivePush.withDependencies(
      api: api,
      messaging: messaging ?? FirebasePushMessaging(),
      storage: store,
      platform: plat,
      environment: plat == PushPlatform.ios
          ? (environment ?? (kDebugMode ? ApnsEnvironment.sandbox : ApnsEnvironment.production))
          : null,
      appVersion: appVersion,
      locale: locale ?? _deviceLocale(),
      timezone: timezone,
      deviceId: deviceId,
    );
    await _instance?.dispose();
    _instance = push;
    if (autoRegister) push._listenTokenRefresh();
    if (trackOpens) await push._trackOpens();
    return push;
  }

  /// The plain HTTP client this SDK uses.
  final HivePushApi api;
  final PushMessaging _messaging;
  final HivePushStorage _storage;

  /// `ios` or `android`; null on platforms without native push (inbox only).
  final PushPlatform? platform;

  /// The iOS push environment sent with registrations (null on Android).
  final ApnsEnvironment? environment;
  final String? appVersion;
  final String? locale;
  final String? timezone;

  /// The in-app inbox.
  late final HivePushInbox inbox;

  String? _deviceId;
  String? _userId;
  String? _userToken;
  Map<String, String>? _tags;
  Future<Registration>? _registering;
  bool _registerRequested = false;
  final List<StreamSubscription<dynamic>> _subs = [];
  final Set<String> _reportedOpens = {};

  /// This install's device id (`dev_...`), or null before [register].
  String? get deviceId => _deviceId;

  /// The signed-in user set with [setUser], or null.
  String? get userId => _userId;

  /// Asks the user for permission to show notifications. Throws
  /// `permission_denied` when they refuse.
  Future<void> requestPermission() async {
    final ok = await _messaging.requestPermission();
    if (!ok) {
      throw HivePushException('Notification permission was not granted', code: 'permission_denied');
    }
  }

  /// Gets this install's push token (APNs on iOS, FCM on Android) and
  /// registers it. Call it on every launch after permission is granted: the
  /// same token just updates the existing device.
  Future<Registration> register() {
    _registerRequested = true;
    return _registering ??= _register().whenComplete(() => _registering = null);
  }

  Future<Registration> _register() async {
    final plat = platform;
    if (plat == null) {
      throw HivePushException('Push registration needs iOS or Android', code: 'unsupported');
    }
    final token = await _messaging.getToken(plat);
    if (token == null || token.isEmpty) {
      throw HivePushException(
        plat == PushPlatform.ios
            ? 'iOS has not issued an APNs token yet: check the Push Notifications capability and call requestPermission() first'
            : 'Firebase has not issued a push token yet',
        code: 'no_token',
      );
    }
    final reg = await api.registerDevice(
      platform: plat,
      token: token,
      environment: environment,
      userToken: _userToken,
      tags: _tags,
      appVersion: appVersion,
      locale: locale,
      timezone: timezone,
    );
    await _setDeviceId(reg.deviceId);
    return reg;
  }

  /// Attaches your signed-in user to this install and enables the inbox.
  /// [token] is a user token made by your server. Call it on every launch
  /// while the user is signed in (tokens expire).
  Future<void> setUser(String userId, String token) async {
    if (token.isEmpty) {
      throw HivePushException('setUser needs the user token from your server', code: 'invalid_user_token');
    }
    _userId = userId;
    _userToken = token;
    inbox._stream.restart();
    await _patch(() => api.updateDevice(_deviceId!, userToken: token));
  }

  /// Logs out: the install keeps receiving pushes sent to everyone or to its
  /// tags, but no longer belongs to a user.
  Future<void> clearUser() async {
    _userId = null;
    _userToken = null;
    inbox._stream.restart();
    await _patch(() => api.updateDevice(_deviceId!, clearUser: true));
  }

  /// Replaces this install's tags (string values, at most 20 keys).
  Future<void> setTags(Map<String, String> tags) async {
    _tags = Map.of(tags);
    await _patch(() => api.updateDevice(_deviceId!, tags: _tags));
  }

  /// Removes this install from Hive Push (for example when the user turns
  /// notifications off in your settings). Call [register] to come back.
  Future<void> unregister() async {
    _registerRequested = false;
    final id = _deviceId;
    await _setDeviceId(null);
    if (id != null) await api.deleteDevice(id);
  }

  /// Reports that the user opened [message] (counts as `clicked`). Returns
  /// false when it is not a Hive Push notification or the install is not
  /// registered.
  Future<bool> reportOpened(RemoteMessage message) => reportOpenedData(message.data);

  /// Same as [reportOpened], from the notification's data / `userInfo`
  /// (reads `hp_id` on Android and `hp.id` on iOS).
  Future<bool> reportOpenedData(Map<dynamic, dynamic> data) async {
    final id = notificationIdFrom(data);
    if (id == null || _deviceId == null) return false;
    await reportEvent(id, PushEventType.clicked);
    return true;
  }

  /// Reports an event for a notification id (`ntf_...`).
  Future<void> reportEvent(String notificationId, PushEventType type) async {
    final id = _deviceId;
    if (id == null) {
      throw HivePushException('Call register() first', code: 'not_registered');
    }
    await api.sendEvent(deviceId: id, notificationId: notificationId, type: type);
  }

  /// The Hive Push notification id in a notification's data: `hp_id`
  /// (Android) or `hp.id` (iOS, as a map or a JSON string). Null when absent.
  static String? notificationIdFrom(Map<dynamic, dynamic> data) {
    final flat = data['hp_id'];
    if (flat is String && flat.isNotEmpty) return flat;
    var hp = data['hp'];
    if (hp is String) {
      try {
        hp = jsonDecode(hp);
      } catch (_) {
        return null;
      }
    }
    if (hp is Map) {
      final id = hp['id'];
      if (id is String && id.isNotEmpty) return id;
    }
    final dotted = data['hp.id'];
    if (dotted is String && dotted.isNotEmpty) return dotted;
    return null;
  }

  /// Stops listening for token changes and opens, and closes the inbox stream.
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await inbox._stream.close();
    if (identical(_instance, this)) _instance = null;
  }

  String? get _needUserToken {
    final t = _userToken;
    if (t == null) {
      throw HivePushException('Call setUser(userId, token) before using the inbox', code: 'invalid_user_token');
    }
    return t;
  }

  Future<void> _patch(Future<void> Function() call) async {
    if (_deviceId == null) return; // sent with the next register()
    try {
      await call();
    } on HivePushException catch (e) {
      if (e.status != 404) rethrow;
      // The device was removed on the service side: register it again, which
      // carries the current user and tags.
      await _setDeviceId(null);
      if (platform != null) await register();
    }
  }

  Future<void> _setDeviceId(String? id) async {
    _deviceId = id;
    await _storage.write(_deviceKey(api.key), id);
  }

  void _listenTokenRefresh() {
    _subs.add(_messaging.onTokenRefresh.listen((_) {
      if (!_registerRequested && _deviceId == null) return;
      register().catchError((Object _) => Registration(deviceId: _deviceId ?? '', created: false));
    }));
  }

  Future<void> _trackOpens() async {
    _subs.add(_messaging.onNotificationOpened.listen(_autoReport));
    try {
      final initial = await _messaging.getInitialNotification();
      if (initial != null) await _autoReport(initial);
    } catch (_) {/* no launch notification */}
  }

  Future<void> _autoReport(Map<String, dynamic> data) async {
    final id = notificationIdFrom(data);
    if (id == null || !_reportedOpens.add(id)) return;
    try {
      await reportOpenedData(data);
    } catch (_) {/* best effort */}
  }

  static String _deviceKey(String key) => 'hivepush:$key:device';

  static PushPlatform? _currentPlatform() {
    if (kIsWeb) return null;
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return PushPlatform.ios;
      case TargetPlatform.android:
        return PushPlatform.android;
      default:
        return null;
    }
  }

  static String? _deviceLocale() {
    try {
      final tag = PlatformDispatcher.instance.locale.toLanguageTag();
      return _localeRE.hasMatch(tag) && tag.length <= 35 ? tag : null;
    } catch (_) {
      return null;
    }
  }
}

/// The signed-in user's in-app inbox (needs [HivePush.setUser]).
class HivePushInbox {
  HivePushInbox._(this._push) : _stream = InboxStream(api: _push.api, userToken: () => _push._userToken);

  final HivePush _push;
  final InboxStream _stream;

  /// The inbox, newest first. [limit] is at most 50; pass the last item's id
  /// as [before] for the next page.
  Future<InboxPage> list({String? before, int? limit}) =>
      _push.api.listInbox(_push._needUserToken!, before: before, limit: limit);

  /// Marks items as read.
  Future<void> markRead(List<String> ids) => _push.api.markRead(_push._needUserToken!, ids: ids);

  /// Marks every item as read.
  Future<void> markAllRead() => _push.api.markRead(_push._needUserToken!, all: true);

  /// New inbox items, live. Connects while listened to and reconnects on its
  /// own (1 s, doubling to 30 s). An expired user token arrives as a
  /// [HivePushException] error; call [HivePush.setUser] with a fresh one.
  Stream<InboxItem> get messages => _stream.stream;

  /// True when the live connection opens, false when it drops. Re-read the
  /// inbox with [list] on `true` to catch anything sent while offline.
  Stream<bool> get connection => _stream.connection;
}

class _PrefsStorage implements HivePushStorage {
  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  @override
  Future<String?> read(String key) async => (await _prefs).getString(key);

  @override
  Future<void> write(String key, String? value) async {
    final p = await _prefs;
    if (value == null) {
      await p.remove(key);
    } else {
      await p.setString(key, value);
    }
  }
}
