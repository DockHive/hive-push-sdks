import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:hive_push/hive_push.dart';

/// Ask your own server for a user token. It makes one with the app's secret
/// key (never ship the secret key in the app).
Future<String> fetchUserToken(String userId) async {
  throw UnimplementedError('Call your server, e.g. GET https://api.example.com/push-token');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await HivePush.init(key: 'pk_...', region: 'global-1', appVersion: '1.0.0');
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) =>
      MaterialApp(title: 'Hive Push example', theme: ThemeData(useMaterial3: true), home: const InboxScreen());
}

class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  final push = HivePush.instance;
  final items = <InboxItem>[];
  StreamSubscription<InboxItem>? _live;
  StreamSubscription<bool>? _connection;
  String status = 'Not registered';
  int unread = 0;

  Future<void> _enable() async {
    try {
      await push.requestPermission();
      final reg = await push.register();
      setState(() => status = 'Registered as ${reg.deviceId}');
    } on HivePushException catch (e) {
      setState(() => status = 'Could not register: ${e.message}');
    }
  }

  Future<void> _signIn() async {
    try {
      await push.setUser('user-42', await fetchUserToken('user-42'));
      await push.setTags({'plan': 'pro'});
      await _reload();
      _live ??= push.inbox.messages.listen(
        (item) => setState(() {
          items.insert(0, item);
          unread++;
        }),
        onError: (Object e) => setState(() => status = 'Inbox: $e'),
      );
      _connection ??= push.inbox.connection.where((up) => up).listen((_) => _reload());
    } catch (e) {
      setState(() => status = 'Sign-in failed: $e');
    }
  }

  Future<void> _reload() async {
    final page = await push.inbox.list(limit: 20);
    setState(() {
      items
        ..clear()
        ..addAll(page.items);
      unread = page.unread;
    });
  }

  Future<void> _readAll() async {
    await push.inbox.markAllRead();
    await _reload();
  }

  @override
  void dispose() {
    _live?.cancel();
    _connection?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Inbox ($unread unread)'),
        actions: [IconButton(onPressed: _readAll, icon: const Icon(Icons.done_all), tooltip: 'Mark all read')],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 8,
              children: [
                FilledButton(onPressed: _enable, child: const Text('Enable notifications')),
                OutlinedButton(onPressed: _signIn, child: const Text('Sign in')),
              ],
            ),
          ),
          Text(status),
          Expanded(
            child: ListView(
              children: [
                for (final item in items)
                  ListTile(
                    title: Text(item.title ?? ''),
                    subtitle: Text(item.body ?? ''),
                    trailing: item.isRead ? null : const Icon(Icons.circle, size: 10),
                    onTap: () => push.inbox.markRead([item.id]).then((_) => _reload()),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
