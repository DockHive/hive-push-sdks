import { baseURL, HivePushApi, HivePushError } from '../src';
import { mockFetch } from './helpers';

describe('baseURL', () => {
  it('builds from a region or a host', () => {
    expect(baseURL({ region: 'Global-1' })).toBe('https://push-global-1.dockhive.io');
    expect(baseURL({ host: 'push-eu.dockhive.io/' })).toBe('https://push-eu.dockhive.io');
    expect(baseURL({ host: 'http://localhost:8080', region: 'x' })).toBe('http://localhost:8080');
  });
  it('needs one of them', () => {
    expect(() => baseURL({})).toThrow(HivePushError);
  });
});

describe('HivePushApi', () => {
  it('needs a key', () => {
    expect(() => new HivePushApi({ key: '', region: 'global-1' })).toThrow(/key/);
  });

  it('registers an iOS install with the key header and full body', async () => {
    const m = mockFetch(() => ({ status: 201, body: { device_id: 'dev_1' } }));
    const api = new HivePushApi({ key: 'pk_test', region: 'global-1', fetch: m.fetch });
    const reg = await api.registerDevice({
      platform: 'ios',
      token: 'ab'.repeat(32),
      environment: 'sandbox',
      userToken: 'ut',
      tags: { plan: 'pro' },
      appVersion: '1.2.3',
      locale: 'en-NG',
      timezone: 'Africa/Lagos',
    });
    expect(reg).toEqual({ deviceId: 'dev_1', created: true });
    const c = m.calls[0];
    expect(c.method).toBe('POST');
    expect(c.url).toBe('https://push-global-1.dockhive.io/sdk/v1/devices');
    expect(c.headers['X-Hive-Push-Key']).toBe('pk_test');
    expect(c.headers['Content-Type']).toBe('application/json');
    expect(c.body).toEqual({
      platform: 'ios',
      token: 'ab'.repeat(32),
      environment: 'sandbox',
      user_token: 'ut',
      tags: { plan: 'pro' },
      app_version: '1.2.3',
      locale: 'en-NG',
      timezone: 'Africa/Lagos',
    });
  });

  it('never sends environment for Android', async () => {
    const m = mockFetch(() => ({ status: 200, body: { device_id: 'dev_2' } }));
    const api = new HivePushApi({ key: 'pk_test', region: 'global-1', fetch: m.fetch });
    const reg = await api.registerDevice({ platform: 'android', token: 'fcm:tok', environment: 'production' });
    expect(reg.created).toBe(false);
    expect(m.calls[0].body).toEqual({ platform: 'android', token: 'fcm:tok' });
  });

  it('turns error answers into HivePushError', async () => {
    const m = mockFetch(() => ({
      status: 409,
      body: { error: 'iOS push is not set up for this app yet', code: 'platform_not_configured' },
    }));
    const api = new HivePushApi({ key: 'pk_test', region: 'global-1', fetch: m.fetch });
    await expect(api.registerDevice({ platform: 'ios', token: 'ab'.repeat(32) })).rejects.toMatchObject({
      name: 'HivePushError',
      code: 'platform_not_configured',
      status: 409,
      message: expect.stringContaining('not set up'),
    });
  });

  it('reads Retry-After and falls back to http_<status>', async () => {
    let n = 0;
    const m = mockFetch(() =>
      ++n === 1
        ? { status: 429, body: { error: 'slow down', code: 'rate_limited' }, headers: { 'Retry-After': '60' } }
        : { status: 502, body: '<html>' },
    );
    const api = new HivePushApi({ key: 'pk_test', region: 'global-1', fetch: m.fetch });
    await expect(api.listInbox('ut')).rejects.toMatchObject({ code: 'rate_limited', retryAfter: 60 });
    await expect(api.listInbox('ut')).rejects.toMatchObject({ code: 'http_502', status: 502 });
  });

  it('reports network failures with code network and status 0', async () => {
    const api = new HivePushApi({
      key: 'pk_test',
      region: 'global-1',
      fetch: async () => {
        throw new TypeError('Network request failed');
      },
    });
    await expect(api.sendEvent('d', 'n', 'clicked')).rejects.toMatchObject({ code: 'network', status: 0 });
  });

  it('patches the device', async () => {
    const m = mockFetch(() => ({ status: 204 }));
    const api = new HivePushApi({ key: 'pk_test', region: 'global-1', fetch: m.fetch });
    await api.updateDevice('dev_1', { userToken: 'ut' });
    await api.updateDevice('dev_1', { clearUser: true });
    await api.updateDevice('dev_1', { tags: { a: 'b' } });
    await api.updateDevice('dev_1', { appVersion: '2.0.0', locale: 'fr', timezone: 'Europe/Paris' });
    await api.updateDevice('dev_1', {});
    expect(m.calls.map((c) => `${c.method} ${c.url}`)).toEqual(
      Array(4).fill('PATCH https://push-global-1.dockhive.io/sdk/v1/devices/dev_1'),
    );
    expect(m.calls.map((c) => c.body)).toEqual([
      { user_token: 'ut' },
      { user_id: null },
      { tags: { a: 'b' } },
      { app_version: '2.0.0', locale: 'fr', timezone: 'Europe/Paris' },
    ]);
  });

  it('treats a missing device as removed', async () => {
    let status = 404;
    const m = mockFetch(() => ({ status, body: { error: 'Device not found.', code: 'not_found' } }));
    const api = new HivePushApi({ key: 'pk_test', region: 'global-1', fetch: m.fetch });
    await api.deleteDevice('dev_1');
    expect(m.calls[0].method).toBe('DELETE');
    status = 500;
    await expect(api.deleteDevice('dev_1')).rejects.toBeInstanceOf(HivePushError);
  });

  it('lists the inbox and marks items read', async () => {
    const m = mockFetch((c) =>
      c.method === 'GET'
        ? { status: 200, body: { items: [{ id: 'inb_1', notification_id: 'ntf_1', read_at: null }], unread: 3 } }
        : { status: 204 },
    );
    const api = new HivePushApi({ key: 'pk_test', host: 'example.test', fetch: m.fetch });
    const page = await api.listInbox('u t', { before: 'inb_9', limit: 20 });
    expect(page.unread).toBe(3);
    expect(page.items[0].id).toBe('inb_1');
    expect(m.calls[0].url).toBe('https://example.test/sdk/v1/inbox?user_token=u%20t&before=inb_9&limit=20');
    await api.markRead('ut', 'inb_1');
    await api.markRead('ut', ['inb_1', 'inb_2']);
    await api.markRead('ut', 'all');
    expect(m.calls.slice(1).map((c) => c.body)).toEqual([
      { user_token: 'ut', ids: ['inb_1'] },
      { user_token: 'ut', ids: ['inb_1', 'inb_2'] },
      { user_token: 'ut', all: true },
    ]);
    expect(m.calls[1].url).toBe('https://example.test/sdk/v1/inbox/read');
  });

  it('sends events', async () => {
    const m = mockFetch(() => ({ status: 204 }));
    const api = new HivePushApi({ key: 'pk_test', region: 'global-1', fetch: m.fetch });
    await api.sendEvent('dev_1', 'ntf_1', 'clicked');
    expect(m.calls[0].url).toBe('https://push-global-1.dockhive.io/sdk/v1/events');
    expect(m.calls[0].body).toEqual({ device_id: 'dev_1', notification_id: 'ntf_1', type: 'clicked' });
  });

  it('builds the stream URL', () => {
    const api = new HivePushApi({ key: 'pk_test', region: 'global-1', fetch: async () => new Response() });
    expect(api.streamURL('a+b')).toBe('https://push-global-1.dockhive.io/sdk/v1/stream?user_token=a%2Bb');
  });
});
