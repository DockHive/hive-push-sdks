import HivePush, { memoryStorage, notificationIdFrom, type NotificationData, type PushMessaging, type PushPlatform, type SseConnect } from '../src';
import { mockFetch, tick, until, type Call } from './helpers';

type Reply = { status: number; body?: unknown; headers?: Record<string, string> };

class FakeMessaging implements PushMessaging {
  granted = true;
  token: string | null = 'ab'.repeat(32);
  asked: PushPlatform[] = [];
  refresh: Array<() => void> = [];
  opened: Array<(d: NotificationData) => void> = [];
  initial: NotificationData | null = null;
  async requestPermission() {
    return this.granted;
  }
  async getToken(p: PushPlatform) {
    this.asked.push(p);
    return this.token;
  }
  onTokenRefresh(l: () => void) {
    this.refresh.push(l);
    return () => (this.refresh = this.refresh.filter((x) => x !== l));
  }
  onNotificationOpened(l: (d: NotificationData) => void) {
    this.opened.push(l);
    return () => (this.opened = this.opened.filter((x) => x !== l));
  }
  async getInitialNotification() {
    return this.initial;
  }
}

function setup(opts: { platform?: PushPlatform | null; environment?: 'sandbox' | 'production'; trackOpens?: boolean; connect?: SseConnect } = {}) {
  const messaging = new FakeMessaging();
  const storage = memoryStorage();
  let respond = (c: Call): Reply =>
    c.method === 'POST' && c.url.endsWith('/devices') ? { status: 201, body: { device_id: 'dev_1' } } : { status: 204 };
  const m = mockFetch((c) => respond(c));
  const make = () =>
    HivePush.init({
      key: 'pk_test',
      region: 'global-1',
      platform: opts.platform === undefined ? 'ios' : opts.platform,
      environment: opts.environment,
      appVersion: '1.0.0',
      locale: 'en-NG',
      timezone: 'Africa/Lagos',
      messaging,
      storage,
      fetch: m.fetch,
      trackOpens: opts.trackOpens,
      connect: opts.connect || (() => ({ close: () => undefined })),
    });
  return {
    messaging,
    storage,
    calls: m.calls,
    make,
    setRespond: (f: typeof respond) => (respond = f),
  };
}

afterEach(() => {
  try {
    HivePush.instance().dispose();
  } catch {
    /* none */
  }
});

describe('HivePush (React Native)', () => {
  it('registers an iOS install with the APNs token, environment and details', async () => {
    const s = setup({ environment: 'production' });
    const push = s.make();
    expect(HivePush.instance()).toBe(push);
    await push.requestPermission();
    const reg = await push.register();
    expect(reg).toEqual({ deviceId: 'dev_1', created: true });
    expect(await push.deviceId()).toBe('dev_1');
    expect(s.storage.values['hivepush:pk_test:device']).toBe('dev_1');
    expect(s.messaging.asked).toEqual(['ios']);
    expect(s.calls[0].headers['X-Hive-Push-Key']).toBe('pk_test');
    expect(s.calls[0].body).toEqual({
      platform: 'ios',
      token: 'ab'.repeat(32),
      environment: 'production',
      app_version: '1.0.0',
      locale: 'en-NG',
      timezone: 'Africa/Lagos',
    });
  });

  it('defaults iOS to production outside development', () => {
    expect(setup().make().environment).toBe('production');
  });

  it('registers an Android install without environment', async () => {
    const s = setup({ platform: 'android', environment: 'sandbox' });
    s.messaging.token = 'fcm-token:abc';
    const push = s.make();
    expect(push.environment).toBeUndefined();
    await push.register();
    expect(s.calls[0].body.platform).toBe('android');
    expect(s.calls[0].body.token).toBe('fcm-token:abc');
    expect(s.calls[0].body).not.toHaveProperty('environment');
  });

  it('shares one registration between concurrent calls', async () => {
    const s = setup();
    const push = s.make();
    await Promise.all([push.register(), push.register()]);
    expect(s.calls).toHaveLength(1);
  });

  it('fails clearly without permission, token or platform', async () => {
    const s = setup();
    const push = s.make();
    s.messaging.granted = false;
    await expect(push.requestPermission()).rejects.toMatchObject({ code: 'permission_denied' });
    s.messaging.token = null;
    await expect(push.register()).rejects.toMatchObject({ code: 'no_token' });
    push.dispose();
    const none = setup({ platform: null }).make();
    await expect(none.register()).rejects.toMatchObject({ code: 'unsupported' });
    expect(s.calls).toHaveLength(0);
  });

  it('sends user and tags set before registration with it', async () => {
    const s = setup();
    const push = s.make();
    await push.setUser('user-42', 'ut_1');
    await push.setTags({ plan: 'pro' });
    expect(s.calls).toHaveLength(0);
    await push.register();
    expect(s.calls[0].body).toMatchObject({ user_token: 'ut_1', tags: { plan: 'pro' } });
    expect(push.userId).toBe('user-42');
  });

  it('patches the device for user, tags and logout', async () => {
    const s = setup();
    const push = s.make();
    await push.register();
    await push.setUser('user-42', 'ut_1');
    await push.setTags({ plan: 'pro' });
    await push.setUser(null);
    await push.setUser('user-7', 'ut_7');
    await push.clearUser();
    const patches = s.calls.slice(1);
    expect(new Set(patches.map((c) => `${c.method} ${c.url}`))).toEqual(
      new Set(['PATCH https://push-global-1.dockhive.io/sdk/v1/devices/dev_1']),
    );
    expect(patches.map((c) => c.body)).toEqual([
      { user_token: 'ut_1' },
      { tags: { plan: 'pro' } },
      { user_id: null },
      { user_token: 'ut_7' },
      { user_id: null },
    ]);
    await expect(push.setUser('u', '')).rejects.toMatchObject({ code: 'invalid_user_token' });
  });

  it('registers again when the device was removed on the service side', async () => {
    const s = setup();
    const push = s.make();
    await push.register();
    s.setRespond((c) =>
      c.method === 'PATCH'
        ? { status: 404, body: { error: 'Device not found.', code: 'not_found' } }
        : { status: 201, body: { device_id: 'dev_2' } },
    );
    await push.setUser('user-42', 'ut_1');
    expect(await push.deviceId()).toBe('dev_2');
    expect(s.calls[s.calls.length - 1].body.user_token).toBe('ut_1');
  });

  it('reuses the stored device id across launches', async () => {
    const s = setup();
    s.storage.values['hivepush:pk_test:device'] = 'dev_old';
    const push = s.make();
    await push.setTags({ a: 'b' });
    expect(s.calls[0].url).toBe('https://push-global-1.dockhive.io/sdk/v1/devices/dev_old');
  });

  it('unregisters', async () => {
    const s = setup();
    const push = s.make();
    await push.register();
    await push.unregister();
    expect(s.calls[1].method).toBe('DELETE');
    expect(s.calls[1].url).toBe('https://push-global-1.dockhive.io/sdk/v1/devices/dev_1');
    expect(await push.deviceId()).toBeNull();
    expect(s.storage.values).toEqual({});
  });

  it('re-registers on token refresh, but only once registered', async () => {
    const s = setup();
    const push = s.make();
    s.messaging.refresh.forEach((l) => l());
    await tick(10);
    expect(s.calls).toHaveLength(0);
    await push.register();
    s.messaging.token = 'cd'.repeat(32);
    s.messaging.refresh.forEach((l) => l());
    await until(() => s.calls.length === 2);
    expect(s.calls[1].body.token).toBe('cd'.repeat(32));
  });

  it('reports opens once per notification, from the launch notification and later taps', async () => {
    const s = setup();
    s.storage.values['hivepush:pk_test:device'] = 'dev_1';
    s.messaging.initial = { hp_id: 'ntf_launch', order_id: '77' };
    const push = s.make();
    await until(() => s.calls.length === 1);
    expect(s.calls[0].url).toBe('https://push-global-1.dockhive.io/sdk/v1/events');
    expect(s.calls[0].body).toEqual({ device_id: 'dev_1', notification_id: 'ntf_launch', type: 'clicked' });
    s.messaging.opened.forEach((l) => l({ hp: { id: 'ntf_ios' } }));
    s.messaging.opened.forEach((l) => l({ hp: { id: 'ntf_ios' } }));
    s.messaging.opened.forEach((l) => l({ other: 'x' }));
    await until(() => s.calls.length === 2);
    await tick(20);
    expect(s.calls).toHaveLength(2);
    expect(await push.reportOpened({ data: { hp: '{"id":"ntf_json"}' } })).toBe(true);
    expect(s.calls[2].body.notification_id).toBe('ntf_json');
  });

  it('does not report opens before registration', async () => {
    const s = setup({ trackOpens: false });
    const push = s.make();
    expect(await push.reportOpenedData({ hp_id: 'ntf_1' })).toBe(false);
    await expect(push.reportEvent('ntf_1', 'delivered')).rejects.toMatchObject({ code: 'not_registered' });
    expect(s.calls).toHaveLength(0);
  });

  it('reads the notification id from Android and iOS data', () => {
    expect(notificationIdFrom({ hp_id: 'a' })).toBe('a');
    expect(notificationIdFrom({ hp: { id: 'b', url: '/x' } })).toBe('b');
    expect(notificationIdFrom({ hp: '{"id":"c"}' })).toBe('c');
    expect(notificationIdFrom({ 'hp.id': 'd' })).toBe('d');
    expect(notificationIdFrom({ hp: 'garbage' })).toBeNull();
    expect(notificationIdFrom({})).toBeNull();
    expect(notificationIdFrom(null)).toBeNull();
  });

  it('inbox needs a user, then uses its token', async () => {
    const s = setup();
    const push = s.make();
    expect(() => push.inbox.list()).toThrow(/setUser/);
    expect(() => push.inbox.onMessage(() => undefined)).toThrow(/setUser/);
    await push.setUser('user-42', 'ut_1');
    s.setRespond((c) => (c.method === 'GET' ? { status: 200, body: { items: [], unread: 0 } } : { status: 204 }));
    expect(await push.inbox.list({ limit: 10 })).toEqual({ items: [], unread: 0 });
    await push.inbox.markRead('all');
    expect(s.calls[0].url).toBe('https://push-global-1.dockhive.io/sdk/v1/inbox?user_token=ut_1&limit=10');
    expect(s.calls[1].body).toEqual({ user_token: 'ut_1', all: true });
  });

  it('live inbox connects with the key and user token, delivers items and restarts on setUser', async () => {
    const opened: Array<{ url: string; headers: Record<string, string>; emit: (data: string) => void; closed: boolean }> = [];
    const s = setup({
      connect: (url, headers, h) => {
        const c = {
          url,
          headers,
          closed: false,
          emit: (data: string) => h.onEvent({ event: 'notification', data }),
        };
        opened.push(c);
        h.onOpen();
        return { close: () => (c.closed = true) };
      },
    });
    const push = s.make();
    await push.setUser('user-42', 'ut_1');
    const got: unknown[] = [];
    const stop = push.inbox.onMessage((i) => got.push(i));
    expect(opened[0].url).toBe('https://push-global-1.dockhive.io/sdk/v1/stream?user_token=ut_1');
    expect(opened[0].headers['X-Hive-Push-Key']).toBe('pk_test');
    expect(opened[0].headers.Accept).toBe('text/event-stream');
    opened[0].emit(JSON.stringify({ id: 'inb_1' }));
    expect(got).toEqual([{ id: 'inb_1' }]);
    await push.setUser('user-42', 'ut_2');
    expect(opened[0].closed).toBe(true);
    expect(opened[1].url).toContain('user_token=ut_2');
    stop();
    expect(opened[1].closed).toBe(true);
  });
});
