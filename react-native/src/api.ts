import { HivePushError } from './errors';
import type { ApnsEnvironment, InboxPage, PushEventType, PushPlatform, Registration } from './types';

export const VERSION = '0.1.0';

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export interface ApiOptions {
  /** The app's public key (`pk_...`). */
  key: string;
  /** Region, for example `global-1`. */
  region?: string;
  /** Or a host: `push-global-1.dockhive.io` or a full `https://` URL. */
  host?: string;
  /** A fetch implementation (defaults to the global `fetch`). */
  fetch?: FetchLike;
}

/** Resolves the service address from a region or a host. */
export function baseURL(opts: { region?: string; host?: string }): string {
  if (opts.host && opts.host.trim()) {
    const h = opts.host.trim().replace(/\/+$/, '');
    return /^https?:\/\//i.test(h) ? h : 'https://' + h;
  }
  if (opts.region && opts.region.trim()) {
    return 'https://push-' + opts.region.trim().toLowerCase() + '.dockhive.io';
  }
  throw new HivePushError('HivePush.init: pass region (e.g. "global-1") or host', 'invalid_options');
}

function query(params: Record<string, string | number | undefined | null>): string {
  const parts: string[] = [];
  for (const k of Object.keys(params)) {
    const v = params[k];
    if (v === undefined || v === null || v === '') continue;
    parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(String(v)));
  }
  return parts.length ? '?' + parts.join('&') : '';
}

/** Parses an error answer into a HivePushError. */
export function errorFromBody(status: number, text: string, retryAfter?: string | null): HivePushError {
  let message: string | undefined;
  let code: string | undefined;
  try {
    const v = JSON.parse(text);
    if (v && typeof v === 'object') {
      if (typeof v.error === 'string') message = v.error;
      if (typeof v.code === 'string') code = v.code;
    }
  } catch {
    /* not JSON */
  }
  const ra = retryAfter ? parseInt(retryAfter, 10) : NaN;
  return new HivePushError(
    message || 'Hive Push request failed (HTTP ' + status + ')',
    code || 'http_' + status,
    status,
    isNaN(ra) ? undefined : ra,
  );
}

export interface RegisterDeviceParams {
  platform: PushPlatform;
  token: string;
  environment?: ApnsEnvironment;
  userToken?: string | null;
  tags?: Record<string, string> | null;
  appVersion?: string;
  locale?: string;
  timezone?: string;
}

export interface UpdateDeviceParams {
  /** Attach a user (token from your server). */
  userToken?: string;
  /** Log out. */
  clearUser?: boolean;
  tags?: Record<string, string>;
  appVersion?: string;
  locale?: string;
  timezone?: string;
}

/**
 * A thin client for the Hive Push app endpoints (`/sdk/v1/...`). `HivePush`
 * builds on it; use it directly if you get push tokens some other way.
 */
export class HivePushApi {
  readonly key: string;
  readonly base: string;
  private readonly fetchImpl: FetchLike;

  constructor(opts: ApiOptions) {
    if (!opts || !opts.key) throw new HivePushError('HivePush.init: key (pk_...) is required', 'invalid_options');
    this.key = opts.key;
    this.base = baseURL(opts);
    const f = opts.fetch || (typeof fetch === 'function' ? fetch.bind(globalThis) : undefined);
    if (!f) throw new HivePushError('No fetch implementation available', 'invalid_options');
    this.fetchImpl = f as FetchLike;
  }

  /** Headers sent with every request. */
  headers(): Record<string, string> {
    return { 'X-Hive-Push-Key': this.key, Accept: 'application/json' };
  }

  url(path: string, params: Record<string, string | number | undefined | null> = {}): string {
    return this.base + '/sdk/v1/' + path + query(params);
  }

  /** The live inbox URL (`GET /sdk/v1/stream`). */
  streamURL(userToken: string): string {
    return this.url('stream', { user_token: userToken });
  }

  private async request(method: string, path: string, body?: unknown, params?: Record<string, string | number | undefined | null>): Promise<{ status: number; data: any }> {
    const headers = this.headers();
    const init: RequestInit = { method, headers };
    if (body !== undefined) {
      headers['Content-Type'] = 'application/json';
      init.body = JSON.stringify(body);
    }
    let res: Response;
    try {
      res = await this.fetchImpl(this.url(path, params), init);
    } catch (e) {
      throw new HivePushError('Network error talking to Hive Push', 'network');
    }
    let text = '';
    try {
      text = await res.text();
    } catch {
      text = '';
    }
    if (res.status < 200 || res.status >= 300) {
      throw errorFromBody(res.status, text, res.headers && res.headers.get ? res.headers.get('Retry-After') : null);
    }
    let data: any = null;
    if (text) {
      try {
        data = JSON.parse(text);
      } catch {
        data = null;
      }
    }
    return { status: res.status, data };
  }

  /** `POST /sdk/v1/devices`: registers (or refreshes) an app install. */
  async registerDevice(p: RegisterDeviceParams): Promise<Registration> {
    const body: Record<string, unknown> = { platform: p.platform, token: p.token };
    if (p.platform === 'ios' && p.environment) body.environment = p.environment;
    if (p.userToken) body.user_token = p.userToken;
    if (p.tags) body.tags = p.tags;
    if (p.appVersion) body.app_version = p.appVersion;
    if (p.locale) body.locale = p.locale;
    if (p.timezone) body.timezone = p.timezone;
    const res = await this.request('POST', 'devices', body);
    const id = res.data && res.data.device_id;
    if (typeof id !== 'string' || !id) {
      throw new HivePushError('Hive Push answered without a device id', 'invalid_response', res.status);
    }
    return { deviceId: id, created: res.status === 201 };
  }

  /** `PATCH /sdk/v1/devices/{id}`. */
  async updateDevice(deviceId: string, p: UpdateDeviceParams): Promise<void> {
    const body: Record<string, unknown> = {};
    if (p.userToken !== undefined) body.user_token = p.userToken;
    else if (p.clearUser) body.user_id = null;
    if (p.tags !== undefined) body.tags = p.tags;
    if (p.appVersion !== undefined) body.app_version = p.appVersion;
    if (p.locale !== undefined) body.locale = p.locale;
    if (p.timezone !== undefined) body.timezone = p.timezone;
    if (Object.keys(body).length === 0) return;
    await this.request('PATCH', 'devices/' + encodeURIComponent(deviceId), body);
  }

  /** `DELETE /sdk/v1/devices/{id}`; a device that is already gone counts as removed. */
  async deleteDevice(deviceId: string): Promise<void> {
    try {
      await this.request('DELETE', 'devices/' + encodeURIComponent(deviceId));
    } catch (e) {
      if (!(e instanceof HivePushError) || e.status !== 404) throw e;
    }
  }

  /** `GET /sdk/v1/inbox`: newest first; `limit` up to 50. */
  async listInbox(userToken: string, opts: { before?: string; limit?: number } = {}): Promise<InboxPage> {
    const res = await this.request('GET', 'inbox', undefined, {
      user_token: userToken,
      before: opts.before,
      limit: opts.limit && opts.limit > 0 ? opts.limit : undefined,
    });
    const d = res.data || {};
    return { items: Array.isArray(d.items) ? d.items : [], unread: typeof d.unread === 'number' ? d.unread : 0 };
  }

  /** `POST /sdk/v1/inbox/read`: ids (at most 200) or `'all'`. */
  async markRead(userToken: string, ids: string | string[] | 'all'): Promise<void> {
    const body: Record<string, unknown> = { user_token: userToken };
    if (ids === 'all') body.all = true;
    else body.ids = Array.isArray(ids) ? ids : [ids];
    await this.request('POST', 'inbox/read', body);
  }

  /** `POST /sdk/v1/events`. */
  async sendEvent(deviceId: string, notificationId: string, type: PushEventType): Promise<void> {
    await this.request('POST', 'events', { device_id: deviceId, notification_id: notificationId, type });
  }
}
