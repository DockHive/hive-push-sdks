import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_push/hive_push_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('resolveBaseUri', () {
    test('region', () {
      expect(HivePushApi.resolveBaseUri(region: 'Global-1').toString(), 'https://push-global-1.dockhive.io');
    });
    test('host without scheme', () {
      expect(HivePushApi.resolveBaseUri(host: 'push-eu.dockhive.io/').toString(), 'https://push-eu.dockhive.io');
    });
    test('host with scheme wins over region', () {
      expect(
          HivePushApi.resolveBaseUri(host: 'http://localhost:8080', region: 'x').toString(), 'http://localhost:8080');
    });
    test('neither', () {
      expect(() => HivePushApi.resolveBaseUri(),
          throwsA(isA<HivePushException>().having((e) => e.code, 'code', 'invalid_options')));
    });
  });

  test('empty key is rejected', () {
    expect(() => HivePushApi(key: '', region: 'global-1'), throwsA(isA<HivePushException>()));
  });

  group('requests', () {
    late List<http.Request> sent;
    late http.Response Function(http.Request) reply;
    late HivePushApi api;

    setUp(() {
      sent = [];
      reply = (_) => http.Response('', 204);
      api = HivePushApi(
        key: 'pk_test',
        region: 'global-1',
        client: MockClient((req) async {
          sent.add(req);
          return reply(req);
        }),
      );
    });

    test('registerDevice (iOS) sends the key header and the body', () async {
      reply = (_) => http.Response(jsonEncode({'device_id': 'dev_1'}), 201);
      final reg = await api.registerDevice(
        platform: PushPlatform.ios,
        token: 'ab' * 32,
        environment: ApnsEnvironment.sandbox,
        userToken: 'ut',
        tags: {'plan': 'pro'},
        appVersion: '1.2.3',
        locale: 'en-NG',
        timezone: 'Africa/Lagos',
      );
      expect(reg.deviceId, 'dev_1');
      expect(reg.created, isTrue);
      final r = sent.single;
      expect(r.method, 'POST');
      expect(r.url.toString(), 'https://push-global-1.dockhive.io/sdk/v1/devices');
      expect(r.headers['X-Hive-Push-Key'], 'pk_test');
      expect(r.headers['Content-Type'], startsWith('application/json'));
      expect(r.headers.containsKey('Origin'), isFalse);
      expect(jsonDecode(r.body), {
        'platform': 'ios',
        'token': 'ab' * 32,
        'environment': 'sandbox',
        'user_token': 'ut',
        'tags': {'plan': 'pro'},
        'app_version': '1.2.3',
        'locale': 'en-NG',
        'timezone': 'Africa/Lagos',
      });
    });

    test('registerDevice (Android) never sends environment', () async {
      reply = (_) => http.Response(jsonEncode({'device_id': 'dev_2'}), 200);
      final reg = await api.registerDevice(
          platform: PushPlatform.android, token: 'fcm:tok', environment: ApnsEnvironment.production);
      expect(reg.created, isFalse);
      expect(jsonDecode(sent.single.body), {'platform': 'android', 'token': 'fcm:tok'});
    });

    test('errors carry code, message, status and Retry-After', () async {
      reply = (_) => http.Response(
            jsonEncode({'error': 'iOS push is not set up for this app yet', 'code': 'platform_not_configured'}),
            409,
          );
      await expectLater(
        api.registerDevice(platform: PushPlatform.ios, token: 'ab' * 32),
        throwsA(isA<HivePushException>()
            .having((e) => e.code, 'code', 'platform_not_configured')
            .having((e) => e.status, 'status', 409)
            .having((e) => e.message, 'message', contains('not set up'))),
      );
      reply = (_) => http.Response(jsonEncode({'error': 'slow down', 'code': 'rate_limited'}), 429,
          headers: {'retry-after': '60'});
      await expectLater(
        api.listInbox('ut'),
        throwsA(isA<HivePushException>().having((e) => e.retryAfter, 'retryAfter', const Duration(seconds: 60))),
      );
    });

    test('non-JSON error body falls back to http_<status>', () async {
      reply = (_) => http.Response('<html>', 502);
      await expectLater(api.sendEvent(deviceId: 'd', notificationId: 'n', type: PushEventType.clicked),
          throwsA(isA<HivePushException>().having((e) => e.code, 'code', 'http_502')));
    });

    test('network errors have code network and status 0', () async {
      final failing =
          HivePushApi(key: 'pk_test', region: 'global-1', client: MockClient((_) => throw Exception('offline')));
      await expectLater(
          failing.listInbox('ut'),
          throwsA(
              isA<HivePushException>().having((e) => e.code, 'code', 'network').having((e) => e.status, 'status', 0)));
    });

    test('updateDevice bodies', () async {
      await api.updateDevice('dev_1', userToken: 'ut');
      await api.updateDevice('dev_1', clearUser: true);
      await api.updateDevice('dev_1', tags: {'a': 'b'});
      await api.updateDevice('dev_1', appVersion: '2.0.0', locale: 'fr', timezone: 'Europe/Paris');
      await api.updateDevice('dev_1'); // nothing to send
      expect(sent.map((r) => r.method).toSet(), {'PATCH'});
      expect(sent.first.url.path, '/sdk/v1/devices/dev_1');
      expect(sent.map((r) => jsonDecode(r.body)).toList(), [
        {'user_token': 'ut'},
        {'user_id': null},
        {
          'tags': {'a': 'b'}
        },
        {'app_version': '2.0.0', 'locale': 'fr', 'timezone': 'Europe/Paris'},
      ]);
    });

    test('deleteDevice treats 404 as done', () async {
      reply = (_) => http.Response(jsonEncode({'error': 'Device not found.', 'code': 'not_found'}), 404);
      await api.deleteDevice('dev_1');
      expect(sent.single.method, 'DELETE');
      reply = (_) => http.Response(jsonEncode({'error': 'x', 'code': 'internal'}), 500);
      await expectLater(api.deleteDevice('dev_1'), throwsA(isA<HivePushException>()));
    });

    test('listInbox query and parsing', () async {
      reply = (_) => http.Response(
            jsonEncode({
              'items': [
                {
                  'id': 'inb_1',
                  'notification_id': 'ntf_1',
                  'created_at': '2026-11-12T09:00:00.123Z',
                  'read_at': null,
                  'title': 'Your order shipped',
                  'body': 'Thursday',
                  'url': 'https://shop.example/orders/77',
                  'data': {'order_id': 77},
                  'extra': true,
                },
              ],
              'unread': 3,
            }),
            200,
          );
      final page = await api.listInbox('u t', before: 'inb_9', limit: 20);
      final q = sent.single.url.queryParameters;
      expect(q, {'user_token': 'u t', 'before': 'inb_9', 'limit': '20'});
      expect(page.unread, 3);
      final item = page.items.single;
      expect(item.id, 'inb_1');
      expect(item.notificationId, 'ntf_1');
      expect(item.isRead, isFalse);
      expect(item.createdAt.toUtc().millisecond, 123);
      expect(item.data, {'order_id': 77});
      expect(item.raw['extra'], isTrue);
    });

    test('markRead ids and all', () async {
      await api.markRead('ut', ids: ['inb_1', 'inb_2']);
      await api.markRead('ut', all: true);
      expect(sent.first.url.path, '/sdk/v1/inbox/read');
      expect(jsonDecode(sent[0].body), {
        'user_token': 'ut',
        'ids': ['inb_1', 'inb_2']
      });
      expect(jsonDecode(sent[1].body), {'user_token': 'ut', 'all': true});
    });

    test('sendEvent', () async {
      await api.sendEvent(deviceId: 'dev_1', notificationId: 'ntf_1', type: PushEventType.clicked);
      expect(sent.single.url.path, '/sdk/v1/events');
      expect(jsonDecode(sent.single.body), {'device_id': 'dev_1', 'notification_id': 'ntf_1', 'type': 'clicked'});
    });

    test('a host with a path keeps it', () async {
      final a = HivePushApi(
          key: 'pk_test',
          host: 'https://example.test/push',
          client: MockClient((req) async {
            sent.add(req);
            return http.Response('', 204);
          }));
      await a.markRead('ut', all: true);
      expect(sent.single.url.toString(), 'https://example.test/push/sdk/v1/inbox/read');
    });
  });
}
