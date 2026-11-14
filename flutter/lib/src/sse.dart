import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'api.dart';
import 'errors.dart';
import 'models.dart';

/// One Server-Sent Event.
class SseEvent {
  SseEvent({required this.event, required this.data, this.id});

  /// The event name (`message` when the server named none).
  final String event;
  final String data;
  final String? id;
}

/// Parses a Server-Sent Events byte stream (comments and `retry:` are skipped).
Stream<SseEvent> parseSse(Stream<List<int>> bytes) async* {
  String? event;
  String? id;
  final data = <String>[];
  await for (final line in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        yield SseEvent(event: event ?? 'message', data: data.join('\n'), id: id);
      }
      event = null;
      data.clear();
      continue;
    }
    if (line.startsWith(':')) continue;
    final i = line.indexOf(':');
    final field = i < 0 ? line : line.substring(0, i);
    var value = i < 0 ? '' : line.substring(i + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        event = value;
      case 'data':
        data.add(value);
      case 'id':
        id = value;
    }
  }
}

/// The live inbox: a broadcast stream of new [InboxItem]s that connects while
/// it has listeners and reconnects on its own (1 s, doubling to 30 s, with
/// jitter).
class InboxStream {
  InboxStream({
    required HivePushApi api,
    required String? Function() userToken,
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
    this.idleTimeout = const Duration(seconds: 70),
    Random? random,
  })  : _api = api,
        _userToken = userToken,
        _random = random ?? Random() {
    _items = StreamController<InboxItem>.broadcast(onListen: _start, onCancel: _stop);
    _connection = StreamController<bool>.broadcast();
  }

  final HivePushApi _api;
  final String? Function() _userToken;
  final Random _random;

  /// First reconnect delay.
  final Duration initialBackoff;

  /// Longest reconnect delay.
  final Duration maxBackoff;

  /// The service sends a keep-alive every 25 s; a connection silent for this
  /// long is treated as dead and reopened.
  final Duration idleTimeout;

  late final StreamController<InboxItem> _items;
  late final StreamController<bool> _connection;
  int _generation = 0;
  Completer<void>? _abort;
  Completer<void>? _sleep;
  bool _connected = false;

  /// New inbox items, as they arrive. Errors that need your action (an expired
  /// user token, an unknown key) are delivered as [HivePushException] stream
  /// errors and the stream waits until [restart] (called by `setUser`).
  Stream<InboxItem> get stream => _items.stream;

  /// True when the live connection opens, false when it drops. Re-read the
  /// inbox with `list()` on `true` to catch anything sent while offline.
  Stream<bool> get connection => _connection.stream;

  /// Whether the live connection is open right now.
  bool get isConnected => _connected;

  /// Reconnects now (for example after the user token changed), if anyone is
  /// listening.
  void restart() {
    if (!_items.hasListener) return;
    _stop();
    _start();
  }

  /// Closes the connection and the streams.
  Future<void> close() async {
    _stop();
    await _items.close();
    await _connection.close();
  }

  void _start() {
    final gen = ++_generation;
    unawaited(_run(gen));
  }

  void _stop() {
    _generation++;
    final a = _abort;
    if (a != null && !a.isCompleted) a.complete();
    final s = _sleep;
    if (s != null && !s.isCompleted) s.complete();
    _setConnected(false);
  }

  void _setConnected(bool v) {
    if (_connected == v) return;
    _connected = v;
    if (!_connection.isClosed) _connection.add(v);
  }

  Future<void> _wait(Duration d, int gen) async {
    if (gen != _generation) return;
    final c = Completer<void>();
    _sleep = c;
    final t = Timer(d, () {
      if (!c.isCompleted) c.complete();
    });
    await c.future;
    t.cancel();
  }

  Future<void> _run(int gen) async {
    var delay = initialBackoff;
    while (gen == _generation) {
      final token = _userToken();
      if (token == null || token.isEmpty) {
        _items.addError(
            HivePushException('Call setUser(userId, token) before using the inbox', code: 'invalid_user_token'));
        return;
      }
      Duration? retryAfter;
      final abort = Completer<void>();
      _abort = abort;
      try {
        final res = await _api.openStream(token, abortTrigger: abort.future);
        if (gen != _generation) {
          if (!abort.isCompleted) abort.complete();
          return;
        }
        delay = initialBackoff;
        _setConnected(true);
        final events = parseSse(res.stream.timeout(idleTimeout, onTimeout: (sink) => sink.close()));
        await for (final ev in events) {
          if (gen != _generation) break;
          if (ev.event != 'notification') continue;
          try {
            final v = jsonDecode(ev.data);
            if (v is Map) _items.add(InboxItem.fromJson(Map<String, dynamic>.from(v)));
          } catch (_) {/* skip a malformed event */}
        }
      } on HivePushException catch (e) {
        if (gen != _generation) return;
        if (_fatal(e)) {
          _setConnected(false);
          _items.addError(e);
          return;
        }
        retryAfter = e.retryAfter;
      } on http.RequestAbortedException {
        // stopped
      } catch (_) {
        // network drop; reconnect below
      } finally {
        if (!abort.isCompleted) abort.complete();
      }
      if (gen != _generation) return;
      _setConnected(false);
      final jitter = Duration(milliseconds: _random.nextInt(500));
      var wait = delay + jitter;
      if (retryAfter != null && retryAfter > wait) wait = retryAfter;
      await _wait(wait, gen);
      final doubled = delay * 2;
      delay = doubled > maxBackoff ? maxBackoff : doubled;
    }
  }

  static bool _fatal(HivePushException e) =>
      e.status == 401 || e.code == 'origin_not_allowed' || e.code == 'app_disabled' || e.status == 404;
}
