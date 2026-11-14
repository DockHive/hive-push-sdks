import { HivePushApi, VERSION, type FetchLike } from './api';
import { HivePushError } from './errors';
import { asyncStorage, currentPlatform, firebaseMessaging } from './native';
import { defaultConnect, LiveInbox, type SseConnect } from './sse';
import type {
  ApnsEnvironment,
  HivePushStorage,
  InboxItem,
  InboxPage,
  NotificationData,
  PushEventType,
  PushMessaging,
  PushPlatform,
  Registration,
} from './types';

declare const __DEV__: boolean | undefined;

const LOCALE_RE = /^[A-Za-z]{2,3}([-_][A-Za-z0-9]{1,8}){0,4}$/;
const TIMEZONE_RE = /^[A-Za-z0-9_+\-/]{1,64}$/;

export interface InitOptions {
  /** The app's public key (`pk_...`). */
  key: string;
  /** Region, for example `global-1`. */
  region?: string;
  /** Or a host: `push-global-1.dockhive.io` or a full `https://` URL. */
  host?: string;
  /** iOS push environment; default `sandbox` in development (`__DEV__`), `production` otherwise. */
  environment?: ApnsEnvironment;
  /** Your app's version (at most 32 characters). */
  appVersion?: string;
  /** Language tag such as `en-NG`; defaults to the device's (from `Intl`). */
  locale?: string;
  /** IANA time zone such as `Africa/Lagos`; defaults to the device's (from `Intl`). */
  timezone?: string;
  /** Register again by itself when the push token changes (default true). */
  autoRegister?: boolean;
  /** Report taps on notifications as `clicked` (default true). */
  trackOpens?: boolean;
  /** Overrides, mostly for tests. */
  messaging?: PushMessaging;
  storage?: HivePushStorage;
  platform?: PushPlatform | null;
  fetch?: FetchLike;
  connect?: SseConnect;
}

export interface OnMessageOptions {
  /** Every connection error, including ones that are retried. An expired user token stops the stream until `setUser`. */
  onError?: (err: HivePushError) => void;
  /** Each time the live connection opens: re-read the inbox with `list()` to catch up. */
  onConnect?: () => void;
}

export interface HivePushInbox {
  /** Newest first; `limit` up to 50; pass the last item's `id` as `before` for the next page. */
  list(opts?: { before?: string; limit?: number }): Promise<InboxPage>;
  /** Marks one id, an array of ids, or `'all'` as read. */
  markRead(ids: string | string[] | 'all'): Promise<void>;
  /** Live inbox: calls `cb(item)` for every new item; reconnects on its own. Returns `stop()`. */
  onMessage(cb: (item: InboxItem) => void, opts?: OnMessageOptions): () => void;
}

function intlDefaults(): { locale?: string; timezone?: string } {
  try {
    const o = new Intl.DateTimeFormat().resolvedOptions();
    return {
      locale: o.locale && LOCALE_RE.test(o.locale) && o.locale.length <= 35 ? o.locale : undefined,
      timezone: o.timeZone && TIMEZONE_RE.test(o.timeZone) ? o.timeZone : undefined,
    };
  } catch {
    return {};
  }
}

/** The Hive Push notification id in a notification's data: `hp_id` (Android) or `hp.id` (iOS). */
export function notificationIdFrom(data: NotificationData | null | undefined): string | null {
  if (!data) return null;
  const flat = data.hp_id;
  if (typeof flat === 'string' && flat) return flat;
  let hp: unknown = data.hp;
  if (typeof hp === 'string') {
    try {
      hp = JSON.parse(hp);
    } catch {
      return null;
    }
  }
  if (hp && typeof hp === 'object') {
    const id = (hp as Record<string, unknown>).id;
    if (typeof id === 'string' && id) return id;
  }
  const dotted = data['hp.id'];
  return typeof dotted === 'string' && dotted ? dotted : null;
}

/**
 * Hive Push for React Native: registers the install for iOS / Android push,
 * keeps its user and tags in sync, reports opens and gives you the in-app
 * inbox. Create it with `HivePush.init(...)`.
 */
export class HivePushClient {
  readonly api: HivePushApi;
  /** `ios` or `android`; null where native push is not available (inbox only). */
  readonly platform: PushPlatform | null;
  /** The iOS environment sent with registrations (undefined on Android). */
  readonly environment?: ApnsEnvironment;
  readonly inbox: HivePushInbox;
  /** Resolves once the stored device id has been loaded. */
  readonly ready: Promise<void>;

  private readonly messaging: PushMessaging;
  private readonly storage: HivePushStorage;
  private readonly storageKey: string;
  private readonly connect: SseConnect;
  private readonly details: { appVersion?: string; locale?: string; timezone?: string };
  private _deviceId: string | null = null;
  private _userId: string | null = null;
  private _token: string | null = null;
  private _tags: Record<string, string> | null = null;
  private registering: Promise<Registration> | null = null;
  private registerRequested = false;
  private readonly unsubs: Array<() => void> = [];
  private readonly lives = new Set<LiveInbox>();
  private readonly reportedOpens = new Set<string>();

  constructor(opts: InitOptions) {
    this.api = new HivePushApi(opts);
    this.platform = opts.platform !== undefined ? opts.platform : currentPlatform();
    if (this.platform === 'ios') {
      this.environment = opts.environment || (typeof __DEV__ !== 'undefined' && __DEV__ ? 'sandbox' : 'production');
    }
    const intl = intlDefaults();
    this.details = {
      appVersion: opts.appVersion,
      locale: opts.locale !== undefined ? opts.locale : intl.locale,
      timezone: opts.timezone !== undefined ? opts.timezone : intl.timezone,
    };
    this.storage = opts.storage || asyncStorage();
    this.storageKey = 'hivepush:' + this.api.key + ':device';
    this.messaging = opts.messaging || (this.platform ? firebaseMessaging() : nullMessaging());
    this.connect = opts.connect || defaultConnect(opts.fetch);
    this.inbox = {
      list: (o) => this.api.listInbox(this.needToken(), o || {}),
      markRead: (ids) => this.api.markRead(this.needToken(), ids),
      onMessage: (cb, o) => this.onMessage(cb, o || {}),
    };
    this.ready = this.storage
      .getItem(this.storageKey)
      .then((id) => {
        if (id && !this._deviceId) this._deviceId = id;
      })
      .catch(() => undefined);
    if (opts.autoRegister !== false) {
      this.unsubs.push(
        this.messaging.onTokenRefresh(() => {
          if (!this.registerRequested && !this._deviceId) return;
          this.register().catch(() => undefined);
        }),
      );
    }
    if (opts.trackOpens !== false) {
      this.unsubs.push(this.messaging.onNotificationOpened((data) => void this.autoReport(data)));
      this.messaging
        .getInitialNotification()
        .then((data) => (data ? this.autoReport(data) : undefined))
        .catch(() => undefined);
    }
  }

  get version(): string {
    return VERSION;
  }

  /** This install's device id (`dev_...`), kept across launches, or null before `register()`. */
  async deviceId(): Promise<string | null> {
    await this.ready;
    return this._deviceId;
  }

  /** The signed-in user set with `setUser`, or null. */
  get userId(): string | null {
    return this._userId;
  }

  /** Asks the user for permission to show notifications; throws `permission_denied` when refused. */
  async requestPermission(): Promise<void> {
    if (!(await this.messaging.requestPermission())) {
      throw new HivePushError('Notification permission was not granted', 'permission_denied');
    }
  }

  /**
   * Gets this install's push token (APNs on iOS, FCM on Android) and registers
   * it. Call it on every launch after permission is granted.
   */
  register(): Promise<Registration> {
    this.registerRequested = true;
    if (!this.registering) {
      this.registering = this.doRegister().finally(() => {
        this.registering = null;
      });
    }
    return this.registering;
  }

  private async doRegister(): Promise<Registration> {
    await this.ready;
    const platform = this.platform;
    if (!platform) throw new HivePushError('Push registration needs iOS or Android', 'unsupported');
    const token = await this.messaging.getToken(platform);
    if (!token) {
      throw new HivePushError(
        platform === 'ios'
          ? 'iOS has not issued an APNs token yet: check the Push Notifications capability and call requestPermission() first'
          : 'Firebase has not issued a push token yet',
        'no_token',
      );
    }
    const reg = await this.api.registerDevice({
      platform,
      token,
      environment: this.environment,
      userToken: this._token,
      tags: this._tags,
      ...this.details,
    });
    await this.setDeviceId(reg.deviceId);
    return reg;
  }

  /**
   * Attaches your signed-in user (token minted by your server) and enables the
   * inbox. `setUser(null)` logs out.
   */
  async setUser(userId: string | null, token?: string): Promise<void> {
    if (userId == null) return this.clearUser();
    if (!token) throw new HivePushError('setUser needs the user token from your server', 'invalid_user_token');
    this._userId = String(userId);
    this._token = token;
    this.lives.forEach((l) => l.restart());
    await this.patch((id) => this.api.updateDevice(id, { userToken: token }));
  }

  /** Logs out: the install no longer belongs to a user. */
  async clearUser(): Promise<void> {
    this._userId = null;
    this._token = null;
    this.lives.forEach((l) => l.stop());
    await this.patch((id) => this.api.updateDevice(id, { clearUser: true }));
  }

  /** Replaces this install's tags (string values, at most 20 keys). */
  async setTags(tags: Record<string, string>): Promise<void> {
    this._tags = { ...(tags || {}) };
    const t = this._tags;
    await this.patch((id) => this.api.updateDevice(id, { tags: t }));
  }

  /** Removes this install from Hive Push. Call `register()` to come back. */
  async unregister(): Promise<void> {
    await this.ready;
    this.registerRequested = false;
    const id = this._deviceId;
    await this.setDeviceId(null);
    if (id) await this.api.deleteDevice(id);
  }

  /** Reports that the user opened a notification (a Firebase `RemoteMessage`). */
  reportOpened(message: { data?: NotificationData } | null | undefined): Promise<boolean> {
    return this.reportOpenedData((message && message.data) || {});
  }

  /** Same, from the notification's data / `userInfo`. False when it is not a Hive Push notification or the install is not registered. */
  async reportOpenedData(data: NotificationData): Promise<boolean> {
    await this.ready;
    const id = notificationIdFrom(data);
    if (!id || !this._deviceId) return false;
    await this.reportEvent(id, 'clicked');
    return true;
  }

  /** Reports `delivered`, `clicked` or `dismissed` for a notification id. */
  async reportEvent(notificationId: string, type: PushEventType): Promise<void> {
    await this.ready;
    if (!this._deviceId) throw new HivePushError('Call register() first', 'not_registered');
    await this.api.sendEvent(this._deviceId, notificationId, type);
  }

  /** Stops listening for token changes and opens, and closes live inbox streams. */
  dispose(): void {
    this.unsubs.splice(0).forEach((u) => {
      try {
        u();
      } catch {
        /* ignore */
      }
    });
    this.lives.forEach((l) => l.stop());
    this.lives.clear();
  }

  private needToken(): string {
    if (!this._token) throw new HivePushError('Call setUser(userId, token) before using the inbox', 'invalid_user_token');
    return this._token;
  }

  private onMessage(cb: (item: InboxItem) => void, o: OnMessageOptions): () => void {
    this.needToken();
    const live = new LiveInbox({
      connect: this.connect,
      url: () => (this._token ? this.api.streamURL(this._token) : null),
      headers: { ...this.api.headers(), Accept: 'text/event-stream', 'Cache-Control': 'no-store' },
      onItem: cb,
      onError: o.onError,
      onConnect: o.onConnect,
    });
    this.lives.add(live);
    live.start();
    return () => {
      live.stop();
      this.lives.delete(live);
    };
  }

  private async patch(call: (deviceId: string) => Promise<void>): Promise<void> {
    await this.ready;
    const id = this._deviceId;
    if (!id) return; // sent with the next register()
    try {
      await call(id);
    } catch (e) {
      if (!(e instanceof HivePushError) || e.status !== 404) throw e;
      // Removed on the service side: register again with the current user and tags.
      await this.setDeviceId(null);
      if (this.platform) await this.register();
    }
  }

  private async setDeviceId(id: string | null): Promise<void> {
    this._deviceId = id;
    try {
      if (id) await this.storage.setItem(this.storageKey, id);
      else await this.storage.removeItem(this.storageKey);
    } catch {
      /* storage unavailable: the id lives for this session */
    }
  }

  private async autoReport(data: NotificationData): Promise<void> {
    const id = notificationIdFrom(data);
    if (!id || this.reportedOpens.has(id)) return;
    this.reportedOpens.add(id);
    try {
      await this.reportOpenedData(data);
    } catch {
      /* best effort */
    }
  }
}

function nullMessaging(): PushMessaging {
  return {
    requestPermission: async () => false,
    getToken: async () => null,
    onTokenRefresh: () => () => undefined,
    onNotificationOpened: () => () => undefined,
    getInitialNotification: async () => null,
  };
}
