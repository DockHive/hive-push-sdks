import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_push/hive_push.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FakeMessaging implements PushMessaging {
  bool granted = true;
  String? token = 'ab' * 32;
  final refresh = StreamController<void>.broadcast();
  final opened = StreamController<Map<String, dynamic>>.broadcast();
  Map<String, dynamic>? initial;
  final asked = <PushPlatform>[];

  @override
  Future<bool> requestPermission() async => granted;

  @override
  Future<String?> getToken(PushPlatform platform) async {
    asked.add(platform);
    return token;
  }

  @override
  Stream<void> get onTokenRefresh => refresh.stream;

  @override
  Stream<Map<String, dynamic>> get onNotificationOpened => opened.stream;

  @override
  Future<Map<String, dynamic>?> getInitialNotification() async => initial;
}

void main() {
  late FakeMessaging messaging;
  late MemoryHivePushStorage storage;
  late List<http.Request> sent;
  late http.Response Function(http.Request) reply;

  setUp(() {
    messaging = FakeMessaging();
    storage = MemoryHivePushStorage();
    sent = [];
    reply = (req) {
      if (req.method == 'POST' && req.url.path.endsWith('/devices')) {
        return http.Response(jsonEncode({'device_id': 'dev_1'}), 201);
      }
      return http.Response('', 204);
    };
  });

  Future<HivePush> init(
      {PushPlatform platform = PushPlatform.ios, ApnsEnvironment? environment, bool trackOpens = true}) {
    return HivePush.init(
      key: 'pk_test',
      region: 'global-1',
      platform: platform,
      environment: environment,
      appVersion: '1.0.0',
      locale: 'en-NG',
      timezone: 'Africa/Lagos',
      messaging: messaging,
      storage: storage,
      trackOpens: trackOpens,
      httpClient: MockClient((req) async {
        sent.add(req);
        return reply(req);
      }),
    );
  }

  Map<String, dynamic> body(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;

  tearDown(() async {
    try {
      await HivePush.instance.dispose();
    } on HivePushException {
      // no client in this test
    }
  });

  test('register on iOS sends the APNs token, environment and details, and keeps the device id', () async {
    final push = await init(environment: ApnsEnvironment.production);
    await push.requestPermission();
    final reg = await push.register();
    expect(reg.deviceId, 'dev_1');
    expect(push.deviceId, 'dev_1');
    expect(storage.values['hivepush:pk_test:device'], 'dev_1');
    expect(messaging.asked, [PushPlatform.ios]);
    expect(body(sent.single), {
      'platform': 'ios',
      'token': 'ab' * 32,
      'environment': 'production',
      'app_version': '1.0.0',
      'locale': 'en-NG',
      'timezone': 'Africa/Lagos',
    });
  });

  test('iOS defaults to sandbox in debug (tests run in debug mode)', () async {
    final push = await init();
    expect(push.environment, ApnsEnvironment.sandbox);
  });

  test('register on Android sends the FCM token and no environment', () async {
    messaging.token = 'fcm-token:abc';
    final push = await init(platform: PushPlatform.android, environment: ApnsEnvironment.production);
    expect(push.environment, isNull);
    await push.register();
    expect(body(sent.single)['platform'], 'android');
    expect(body(sent.single)['token'], 'fcm-token:abc');
    expect(body(sent.single).containsKey('environment'), isFalse);
  });

  test('permission denied and missing token', () async {
    final push = await init();
    messaging.granted = false;
    await expectLater(
        push.requestPermission(), throwsA(isA<HivePushException>().having((e) => e.code, 'code', 'permission_denied')));
    messaging.token = null;
    await expectLater(push.register(), throwsA(isA<HivePushException>().having((e) => e.code, 'code', 'no_token')));
    expect(sent, isEmpty);
  });

  test('user and tags set before register go with the registration', () async {
    final push = await init();
    await push.setUser('user-42', 'ut_1');
    await push.setTags({'plan': 'pro'});
    expect(sent, isEmpty);
    await push.register();
    expect(body(sent.single)['user_token'], 'ut_1');
    expect(body(sent.single)['tags'], {'plan': 'pro'});
    expect(push.userId, 'user-42');
  });

  test('after register, setUser / clearUser / setTags patch the device', () async {
    final push = await init();
    await push.register();
    await push.setUser('user-42', 'ut_1');
    await push.setTags({'plan': 'pro'});
    await push.clearUser();
    final patches = sent.skip(1).toList();
    expect(patches.map((r) => '${r.method} ${r.url.path}').toSet(), {'PATCH /sdk/v1/devices/dev_1'});
    expect(patches.map(body).toList(), [
      {'user_token': 'ut_1'},
      {
        'tags': {'plan': 'pro'}
      },
      {'user_id': null},
    ]);
    expect(push.userId, isNull);
  });

  test('setUser rejects an empty token', () async {
    final push = await init();
    await expectLater(push.setUser('u', ''), throwsA(isA<HivePushException>()));
  });

  test('a device removed on the service side is registered again with the user', () async {
    final push = await init();
    await push.register();
    reply = (req) {
      if (req.method == 'PATCH') {
        return http.Response(jsonEncode({'error': 'Device not found.', 'code': 'not_found'}), 404);
      }
      return http.Response(jsonEncode({'device_id': 'dev_2'}), 201);
    };
    await push.setUser('user-42', 'ut_1');
    expect(push.deviceId, 'dev_2');
    expect(sent.last.method, 'POST');
    expect(body(sent.last)['user_token'], 'ut_1');
  });

  test('the stored device id is reused across launches', () async {
    storage.values['hivepush:pk_test:device'] = 'dev_old';
    final push = await init();
    expect(push.deviceId, 'dev_old');
    await push.setTags({'a': 'b'});
    expect(sent.single.url.path, '/sdk/v1/devices/dev_old');
  });

  test('unregister deletes the device and forgets it', () async {
    final push = await init();
    await push.register();
    await push.unregister();
    expect(sent.last.method, 'DELETE');
    expect(sent.last.url.path, '/sdk/v1/devices/dev_1');
    expect(push.deviceId, isNull);
    expect(storage.values.containsKey('hivepush:pk_test:device'), isFalse);
  });

  test('a token refresh re-registers', () async {
    final push = await init();
    await push.register();
    messaging.token = 'cd' * 32;
    messaging.refresh.add(null);
    await pumpUntil(() => sent.length == 2);
    expect(body(sent.last)['token'], 'cd' * 32);
    expect(push.deviceId, 'dev_1');
  });

  test('a token refresh before any registration does nothing', () async {
    await init();
    messaging.refresh.add(null);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(sent, isEmpty);
  });

  test('opens are reported once per notification (Android data and iOS hp block)', () async {
    storage.values['hivepush:pk_test:device'] = 'dev_1';
    messaging.initial = {'hp_id': 'ntf_launch', 'order_id': '77'};
    final push = await init();
    await pumpUntil(() => sent.isNotEmpty);
    expect(body(sent.single), {'device_id': 'dev_1', 'notification_id': 'ntf_launch', 'type': 'clicked'});
    messaging.opened.add({
      'hp': {'id': 'ntf_ios'}
    });
    messaging.opened.add({
      'hp': {'id': 'ntf_ios'}
    });
    messaging.opened.add({'other': 'x'});
    await pumpUntil(() => sent.length == 2);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(sent.length, 2);
    expect(body(sent.last)['notification_id'], 'ntf_ios');
    expect(await push.reportOpenedData({'hp': '{"id":"ntf_json"}'}), isTrue);
    expect(body(sent.last)['notification_id'], 'ntf_json');
  });

  test('reportOpenedData without registration returns false', () async {
    final push = await init(trackOpens: false);
    expect(await push.reportOpenedData({'hp_id': 'ntf_1'}), isFalse);
    expect(sent, isEmpty);
    await expectLater(push.reportEvent('ntf_1', PushEventType.delivered),
        throwsA(isA<HivePushException>().having((e) => e.code, 'code', 'not_registered')));
  });

  test('notificationIdFrom', () {
    expect(HivePush.notificationIdFrom({'hp_id': 'a'}), 'a');
    expect(
        HivePush.notificationIdFrom({
          'hp': {'id': 'b', 'url': '/x'}
        }),
        'b');
    expect(HivePush.notificationIdFrom({'hp': '{"id":"c"}'}), 'c');
    expect(HivePush.notificationIdFrom({'hp.id': 'd'}), 'd');
    expect(HivePush.notificationIdFrom({'hp': 'garbage'}), isNull);
    expect(HivePush.notificationIdFrom({}), isNull);
  });

  test('inbox needs a user; then lists and marks read with the user token', () async {
    final push = await init();
    expect(
        () => push.inbox.list(), throwsA(isA<HivePushException>().having((e) => e.code, 'code', 'invalid_user_token')));
    await push.setUser('user-42', 'ut_1');
    reply = (req) {
      if (req.method == 'GET') {
        return http.Response(jsonEncode({'items': [], 'unread': 0}), 200);
      }
      return http.Response('', 204);
    };
    final page = await push.inbox.list(limit: 10);
    expect(page.items, isEmpty);
    await push.inbox.markRead(['inb_1']);
    await push.inbox.markAllRead();
    expect(sent[0].url.queryParameters, {'user_token': 'ut_1', 'limit': '10'});
    expect(body(sent[1]), {
      'user_token': 'ut_1',
      'ids': ['inb_1']
    });
    expect(body(sent[2]), {'user_token': 'ut_1', 'all': true});
  });

  test('instance throws before init', () async {
    final push = await init();
    await push.dispose();
    expect(() => HivePush.instance, throwsA(isA<HivePushException>()));
  });
}

Future<void> pumpUntil(bool Function() cond, {Duration timeout = const Duration(seconds: 3)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
