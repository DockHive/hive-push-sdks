/// The platform a device registers as.
enum PushPlatform {
  ios,
  android;

  String get wireName => name;
}

/// The Apple push environment of an iOS install.
///
/// Debug builds installed from Xcode get `sandbox` tokens; TestFlight and App
/// Store builds get `production` tokens.
enum ApnsEnvironment {
  sandbox,
  production;

  String get wireName => name;
}

/// The kind of event an app reports for a notification.
enum PushEventType {
  delivered,
  clicked,
  dismissed;

  String get wireName => name;
}

/// One item of a user's in-app inbox.
class InboxItem {
  InboxItem({
    required this.id,
    required this.notificationId,
    required this.createdAt,
    this.readAt,
    this.title,
    this.body,
    this.url,
    this.icon,
    this.image,
    this.data,
    required this.raw,
  });

  factory InboxItem.fromJson(Map<String, dynamic> json) {
    final data = json['data'];
    return InboxItem(
      id: json['id'] as String? ?? '',
      notificationId: json['notification_id'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      readAt: json['read_at'] is String ? DateTime.tryParse(json['read_at'] as String) : null,
      title: json['title'] as String?,
      body: json['body'] as String?,
      url: json['url'] as String?,
      icon: json['icon'] as String?,
      image: json['image'] as String?,
      data: data is Map ? Map<String, dynamic>.from(data) : null,
      raw: Map<String, dynamic>.unmodifiable(json),
    );
  }

  /// The inbox item id (`inb_...`); pass it to `markRead` or as `before`.
  final String id;

  /// The notification this item came from (`ntf_...`).
  final String notificationId;
  final DateTime createdAt;

  /// When the user read it, or null while unread.
  final DateTime? readAt;
  final String? title;
  final String? body;
  final String? url;
  final String? icon;
  final String? image;

  /// The `data` object you sent with the notification.
  final Map<String, dynamic>? data;

  /// The item exactly as the service sent it, including any field this SDK
  /// version does not know yet.
  final Map<String, dynamic> raw;

  bool get isRead => readAt != null;

  @override
  String toString() => 'InboxItem($id, $title)';
}

/// A page of the inbox, newest first.
class InboxPage {
  InboxPage({required this.items, required this.unread});

  factory InboxPage.fromJson(Map<String, dynamic> json) {
    final items = (json['items'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => InboxItem.fromJson(Map<String, dynamic>.from(m)))
        .toList(growable: false);
    return InboxPage(items: items, unread: (json['unread'] as num?)?.toInt() ?? 0);
  }

  final List<InboxItem> items;

  /// How many of the user's items are unread (all pages).
  final int unread;
}

/// The result of registering an install.
class Registration {
  Registration({required this.deviceId, required this.created});

  /// The device id (`dev_...`), kept on the device by the SDK.
  final String deviceId;

  /// True the first time this push token was registered.
  final bool created;
}
