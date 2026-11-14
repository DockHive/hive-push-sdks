import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_push/hive_push_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Stream<List<int>> chunks(List<String> parts) => Stream.fromIterable(parts.map(utf8.encode));

String item(String id) => jsonEncode({
      'id': id,
      'notification_id': 'ntf_$id',
      'created_at': '2026-11-12T09:00:00Z',
      'read_at': null,
      'title': 'Hello $id',
    });

void main() {
  group('parseSse', () {
    test('events, comments, multi-line data, CRLF and split chunks', () async {
      final events = await parseSse(chunks([
        'retry: 3000\n: connected\n\n',
        'id: inb_1\nevent: notifi',
        'cation\ndata: {"a":1}\n\n',
        ': ping\r\n\r\n',
        'data: line1\r\ndata: line2\r\n\r\n',
      ])).toList();
      expect(events.length, 2);
      expect(events[0].event, 'notification');
      expect(events[0].id, 'inb_1');
      expect(events[0].data, '{"a":1}');
      expect(events[1].event, 'message');
      expect(events[1].data, 'line1\nline2');
    });
  });

  group('InboxStream', () {
    late List<http.BaseRequest> requests;
    late List<StreamController<List<int>>> bodies;
    late FutureOr<http.StreamedResponse> Function(int n) respond;
    late HivePushApi api;
    String? token;

    setUp(() {
      requests = [];
      bodies = [];
      token = 'ut';
      respond = (n) {
        final c = StreamController<List<int>>();
        bodies.add(c);
        c.add(utf8.encode('retry: 3000\n: connected\n\n'));
        return http.StreamedResponse(c.stream, 200, headers: {'content-type': 'text/event-stream'});
      };
      api = HivePushApi(
        key: 'pk_test',
        region: 'global-1',
        client: MockClient.streaming((req, _) async {
          requests.add(req);
          return respond(requests.length);
        }),
      );
    });

    tearDown(() async {
      for (final b in bodies) {
        if (!b.isClosed) await b.close();
      }
    });

    InboxStream make({Duration idle = const Duration(seconds: 70)}) => InboxStream(
          api: api,
          userToken: () => token,
          initialBackoff: const Duration(milliseconds: 10),
          maxBackoff: const Duration(milliseconds: 40),
          idleTimeout: idle,
          random: Random(1),
        );

    test('connects on listen with the key header and user token, and emits items', () async {
      final s = make();
      final got = <InboxItem>[];
      final sub = s.stream.listen(got.add);
      await pumpUntil(() => bodies.isNotEmpty);
      final req = requests.single;
      expect(req.url.path, '/sdk/v1/stream');
      expect(req.url.queryParameters['user_token'], 'ut');
      expect(req.headers['X-Hive-Push-Key'], 'pk_test');
      expect(req.headers['Accept'], 'text/event-stream');
      bodies.single.add(utf8.encode('id: inb_1\nevent: notification\ndata: ${item('1')}\n\n'));
      bodies.single.add(utf8.encode(': ping\n\nevent: other\ndata: {}\n\n'));
      bodies.single.add(utf8.encode('event: notification\ndata: not json\n\n'));
      bodies.single.add(utf8.encode('event: notification\ndata: ${item('2')}\n\n'));
      await pumpUntil(() => got.length == 2);
      expect(got.map((i) => i.id), ['1', '2']);
      expect(got.first.title, 'Hello 1');
      expect(s.isConnected, isTrue);
      await sub.cancel();
      expect(s.isConnected, isFalse);
      await s.close();
    });

    test('reconnects after the server closes the stream, and after errors', () async {
      var n = 0;
      respond = (i) {
        n = i;
        if (i == 2) throw Exception('connection reset');
        if (i == 3) {
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode({'error': 'Restarting', 'code': 'unavailable'}))),
            503,
          );
        }
        final c = StreamController<List<int>>();
        bodies.add(c);
        return http.StreamedResponse(c.stream, 200);
      };
      final s = make();
      final states = <bool>[];
      s.connection.listen(states.add);
      final got = <InboxItem>[];
      final sub = s.stream.listen(got.add);
      await pumpUntil(() => bodies.length == 1);
      await bodies[0].close(); // server closed
      await pumpUntil(() => bodies.length == 2);
      expect(n, 4);
      bodies[1].add(utf8.encode('event: notification\ndata: ${item('9')}\n\n'));
      await pumpUntil(() => got.isNotEmpty);
      expect(got.single.id, '9');
      expect(states, [true, false, true]);
      await sub.cancel();
      await s.close();
    });

    test('a silent connection is reopened', () async {
      final s = make(idle: const Duration(milliseconds: 50));
      final sub = s.stream.listen((_) {});
      await pumpUntil(() => requests.length >= 2);
      await sub.cancel();
      await s.close();
    });

    test('an invalid user token is reported and not retried until restart', () async {
      respond = (i) {
        if (i == 1) {
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode({'error': 'expired', 'code': 'invalid_user_token'}))),
            401,
          );
        }
        final c = StreamController<List<int>>();
        bodies.add(c);
        return http.StreamedResponse(c.stream, 200);
      };
      final s = make();
      final errors = <Object>[];
      final sub = s.stream.listen((_) {}, onError: errors.add);
      await pumpUntil(() => errors.isNotEmpty);
      expect((errors.single as HivePushException).code, 'invalid_user_token');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(requests.length, 1);
      token = 'fresh';
      s.restart();
      await pumpUntil(() => requests.length == 2);
      expect(requests[1].url.queryParameters['user_token'], 'fresh');
      await sub.cancel();
      await s.close();
    });

    test('no user token: error, no request', () async {
      token = null;
      final s = make();
      final errors = <Object>[];
      final sub = s.stream.listen((_) {}, onError: errors.add);
      await pumpUntil(() => errors.isNotEmpty);
      expect(requests, isEmpty);
      await sub.cancel();
      await s.close();
    });
  });
}

Future<void> pumpUntil(bool Function() cond, {Duration timeout = const Duration(seconds: 3)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
