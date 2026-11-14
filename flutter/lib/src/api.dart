import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'models.dart';

/// The version of this SDK.
const String hivePushSdkVersion = '0.1.0';

/// A thin client for the Hive Push app endpoints (`/sdk/v1/...`).
///
/// It is plain Dart (no Flutter, no Firebase): [HivePush] builds on it, and you
/// can use it directly if you get push tokens some other way.
class HivePushApi {
  HivePushApi({
    required this.key,
    String? region,
    String? host,
    http.Client? client,
    String? userAgent,
  })  : baseUri = resolveBaseUri(region: region, host: host),
        _client = client ?? http.Client(),
        _userAgent = userAgent ?? 'hive_push-flutter/$hivePushSdkVersion' {
    if (key.isEmpty) {
      throw HivePushException('HivePush: key (pk_...) is required', code: 'invalid_options');
    }
  }

  /// The app's public key (`pk_...`).
  final String key;

  /// `https://push-<region>.dockhive.io`, or the host you passed.
  final Uri baseUri;

  final http.Client _client;
  final String _userAgent;

  /// The HTTP client, for the live inbox stream.
  http.Client get httpClient => _client;

  /// Resolves the service address from a region (`global-1`) or a host
  /// (`push-global-1.dockhive.io` or a full `https://` URL).
  static Uri resolveBaseUri({String? region, String? host}) {
    if (host != null && host.trim().isNotEmpty) {
      var h = host.trim().replaceAll(RegExp(r'/+$'), '');
      if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(h)) h = 'https://$h';
      return Uri.parse(h);
    }
    if (region != null && region.trim().isNotEmpty) {
      return Uri.parse('https://push-${region.trim().toLowerCase()}.dockhive.io');
    }
    throw HivePushException('HivePush.init: pass region (e.g. "global-1") or host', code: 'invalid_options');
  }

  /// Headers sent with every request.
  Map<String, String> get headers => {
        'X-Hive-Push-Key': key,
        'User-Agent': _userAgent,
        'Accept': 'application/json',
      };

  /// Builds `/sdk/v1/<path>` with an optional query.
  Uri uri(String path, [Map<String, String>? query]) {
    final basePath = baseUri.path.replaceAll(RegExp(r'/+$'), '');
    return baseUri.replace(
      path: '$basePath/sdk/v1/$path',
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );
  }

  /// `POST /sdk/v1/devices`: registers (or refreshes) an app install.
  Future<Registration> registerDevice({
    required PushPlatform platform,
    required String token,
    ApnsEnvironment? environment,
    String? userToken,
    Map<String, String>? tags,
    String? appVersion,
    String? locale,
    String? timezone,
  }) async {
    final body = <String, dynamic>{
      'platform': platform.wireName,
      'token': token,
      if (platform == PushPlatform.ios && environment != null) 'environment': environment.wireName,
      if (userToken != null && userToken.isNotEmpty) 'user_token': userToken,
      if (tags != null) 'tags': tags,
      if (appVersion != null && appVersion.isNotEmpty) 'app_version': appVersion,
      if (locale != null && locale.isNotEmpty) 'locale': locale,
      if (timezone != null && timezone.isNotEmpty) 'timezone': timezone,
    };
    final res = await _send('POST', 'devices', body: body);
    final json = _decodeObject(res);
    final id = json['device_id'];
    if (id is! String || id.isEmpty) {
      throw HivePushException('Hive Push answered without a device id',
          code: 'invalid_response', status: res.statusCode);
    }
    return Registration(deviceId: id, created: res.statusCode == 201);
  }

  /// `PATCH /sdk/v1/devices/{id}`. Pass [userToken] to attach a user,
  /// [clearUser] to log out, [tags] to replace the tags, and any of
  /// [appVersion], [locale], [timezone] to update the install's details.
  Future<void> updateDevice(
    String deviceId, {
    String? userToken,
    bool clearUser = false,
    Map<String, String>? tags,
    String? appVersion,
    String? locale,
    String? timezone,
  }) async {
    final body = <String, dynamic>{
      if (userToken != null) 'user_token': userToken,
      if (userToken == null && clearUser) 'user_id': null,
      if (tags != null) 'tags': tags,
      if (appVersion != null) 'app_version': appVersion,
      if (locale != null) 'locale': locale,
      if (timezone != null) 'timezone': timezone,
    };
    if (body.isEmpty) return;
    await _send('PATCH', 'devices/${Uri.encodeComponent(deviceId)}', body: body);
  }

  /// `DELETE /sdk/v1/devices/{id}`. A device that is already gone counts as
  /// removed.
  Future<void> deleteDevice(String deviceId) async {
    try {
      await _send('DELETE', 'devices/${Uri.encodeComponent(deviceId)}');
    } on HivePushException catch (e) {
      if (e.status != 404) rethrow;
    }
  }

  /// `GET /sdk/v1/inbox`: the user's inbox, newest first. [limit] is at most 50;
  /// pass the last item's id as [before] for the next page.
  Future<InboxPage> listInbox(String userToken, {String? before, int? limit}) async {
    final res = await _send('GET', 'inbox', query: {
      'user_token': userToken,
      if (before != null && before.isNotEmpty) 'before': before,
      if (limit != null && limit > 0) 'limit': '$limit',
    });
    return InboxPage.fromJson(_decodeObject(res));
  }

  /// `POST /sdk/v1/inbox/read`: marks [ids] (at most 200), or everything when
  /// [all] is true, as read.
  Future<void> markRead(String userToken, {List<String>? ids, bool all = false}) async {
    await _send('POST', 'inbox/read', body: {
      'user_token': userToken,
      if (all) 'all': true else 'ids': ids ?? const <String>[],
    });
  }

  /// `POST /sdk/v1/events`: reports a delivered / clicked / dismissed event.
  Future<void> sendEvent({
    required String deviceId,
    required String notificationId,
    required PushEventType type,
  }) async {
    await _send('POST', 'events', body: {
      'device_id': deviceId,
      'notification_id': notificationId,
      'type': type.wireName,
    });
  }

  /// Opens `GET /sdk/v1/stream` (Server-Sent Events). The caller reads and
  /// closes the body; [abortTrigger] completing closes the connection.
  Future<http.StreamedResponse> openStream(String userToken, {Future<void>? abortTrigger}) async {
    final req = http.AbortableRequest('GET', uri('stream', {'user_token': userToken}), abortTrigger: abortTrigger)
      ..headers.addAll(headers)
      ..headers['Accept'] = 'text/event-stream'
      ..headers['Cache-Control'] = 'no-store';
    http.StreamedResponse res;
    try {
      res = await _client.send(req);
    } on http.RequestAbortedException {
      rethrow;
    } catch (e) {
      throw HivePushException('Network error talking to Hive Push: $e', code: 'network');
    }
    if (res.statusCode != 200) {
      final body = await http.Response.fromStream(res);
      throw _errorFrom(body);
    }
    return res;
  }

  /// Closes the HTTP client.
  void close() => _client.close();

  Future<http.Response> _send(String method, String path, {Object? body, Map<String, String>? query}) async {
    final req = http.Request(method, uri(path, query))..headers.addAll(headers);
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req));
    } catch (e) {
      throw HivePushException('Network error talking to Hive Push: $e', code: 'network');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) throw _errorFrom(res);
    return res;
  }

  static Map<String, dynamic> _decodeObject(http.Response res) {
    try {
      final v = jsonDecode(utf8.decode(res.bodyBytes));
      if (v is Map<String, dynamic>) return v;
    } catch (_) {/* fall through */}
    throw HivePushException('Hive Push answered with an unexpected body',
        code: 'invalid_response', status: res.statusCode);
  }

  static HivePushException _errorFrom(http.Response res) {
    String? message;
    String? code;
    try {
      final v = jsonDecode(utf8.decode(res.bodyBytes));
      if (v is Map) {
        message = v['error'] as String?;
        code = v['code'] as String?;
      }
    } catch (_) {/* not JSON */}
    final ra = int.tryParse(res.headers['retry-after'] ?? '');
    return HivePushException(
      message ?? 'Hive Push request failed (HTTP ${res.statusCode})',
      code: code ?? 'http_${res.statusCode}',
      status: res.statusCode,
      retryAfter: ra == null ? null : Duration(seconds: ra),
    );
  }
}
