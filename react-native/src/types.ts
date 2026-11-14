/** The platform an install registers as. */
export type PushPlatform = 'ios' | 'android';

/** The Apple push environment of an iOS install. */
export type ApnsEnvironment = 'sandbox' | 'production';

/** Events an app reports for a notification. */
export type PushEventType = 'delivered' | 'clicked' | 'dismissed';

/** One item of a user's in-app inbox. */
export interface InboxItem {
  /** `inb_...`: pass it to `markRead` or as `before`. */
  id: string;
  /** The notification it came from (`ntf_...`). */
  notification_id: string;
  /** RFC 3339 time. */
  created_at: string;
  /** RFC 3339 time, or null while unread. */
  read_at: string | null;
  title?: string;
  body?: string;
  url?: string;
  icon?: string;
  image?: string;
  /** The `data` object sent with the notification. */
  data?: Record<string, unknown>;
  [key: string]: unknown;
}

/** A page of the inbox, newest first. */
export interface InboxPage {
  items: InboxItem[];
  /** Unread items across all pages. */
  unread: number;
}

/** The result of registering an install. */
export interface Registration {
  deviceId: string;
  /** True the first time this push token was registered. */
  created: boolean;
}

/** Where the SDK keeps the device id between launches (AsyncStorage by default). */
export interface HivePushStorage {
  getItem(key: string): Promise<string | null>;
  setItem(key: string, value: string): Promise<void>;
  removeItem(key: string): Promise<void>;
}

/** Notification data as Firebase or your notification handler gives it. */
export type NotificationData = Record<string, unknown>;

/**
 * What the SDK needs from the operating system's push service. The default
 * uses `@react-native-firebase/messaging`; pass your own for tests or a custom
 * setup.
 */
export interface PushMessaging {
  /** True when the user allowed notifications (including iOS provisional). */
  requestPermission(): Promise<boolean>;
  /** APNs device token as hex on iOS, FCM registration token on Android. */
  getToken(platform: PushPlatform): Promise<string | null>;
  /** Calls `listener` when the operating system issues a new token; returns an unsubscribe function. */
  onTokenRefresh(listener: () => void): () => void;
  /** Calls `listener` with the data of each tapped notification; returns an unsubscribe function. */
  onNotificationOpened(listener: (data: NotificationData) => void): () => void;
  /** The data of the notification that launched the app, if any. */
  getInitialNotification(): Promise<NotificationData | null>;
}
