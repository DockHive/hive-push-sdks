import { connectFetch, connectXhr, HivePushError, LiveInbox, SseParser, type SseEvent, type SseHandlers, type XhrLike } from '../src';
import { until } from './helpers';

const item = (id: string) =>
  JSON.stringify({ id, notification_id: 'ntf_' + id, created_at: '2026-11-12T09:00:00Z', read_at: null, title: 'Hello ' + id });

function recorder() {
  const log: string[] = [];
  const events: SseEvent[] = [];
  const errors: HivePushError[] = [];
  const h: SseHandlers = {
    onOpen: () => log.push('open'),
    onEvent: (e) => events.push(e),
    onError: (e) => {
      log.push('error');
      errors.push(e);
    },
    onClose: () => log.push('close'),
  };
  return { h, log, events, errors };
}

describe('SseParser', () => {
  it('handles comments, retry, multi-line data, CRLF and chunks split anywhere', () => {
    const out: SseEvent[] = [];
    const p = new SseParser((e) => out.push(e));
    const stream = 'retry: 3000\n: connected\n\nid: inb_1\nevent: notification\ndata: {"a":1}\n\n: ping\r\n\r\ndata: line1\r\ndata: line2\r\n\r\n';
    for (const ch of stream) p.push(ch); // one character at a time
    expect(out).toEqual([
      { event: 'notification', data: '{"a":1}', id: 'inb_1' },
      { event: 'message', data: 'line1\nline2', id: 'inb_1' },
    ]);
  });
});

class FakeXhr implements XhrLike {
  readyState = 0;
  status = 0;
  responseText = '';
  onreadystatechange: (() => void) | null = null;
  onprogress: (() => void) | null = null;
  onerror: (() => void) | null = null;
  url = '';
  headers: Record<string, string> = {};
  aborted = false;
  responseHeaders: Record<string, string> = {};
  open(_m: string, url: string) {
    this.url = url;
    this.readyState = 1;
  }
  setRequestHeader(k: string, v: string) {
    this.headers[k] = v;
  }
  getResponseHeader(k: string) {
    return this.responseHeaders[k] ?? null;
  }
  send() {}
  abort() {
    this.aborted = true;
  }
  // test drivers
  headersReceived(status: number) {
    this.status = status;
    this.readyState = 2;
    this.onreadystatechange?.();
  }
  chunk(text: string) {
    this.responseText += text;
    this.readyState = 3;
    this.onreadystatechange?.();
    this.onprogress?.();
  }
  end() {
    this.readyState = 4;
    this.onreadystatechange?.();
  }
}

describe('connectXhr', () => {
  it('streams events as text arrives and sends the headers', () => {
    const x = new FakeXhr();
    const r = recorder();
    connectXhr(() => x, 'https://h/sdk/v1/stream?user_token=t', { 'X-Hive-Push-Key': 'pk_test' }, r.h);
    expect(x.url).toBe('https://h/sdk/v1/stream?user_token=t');
    expect(x.headers['X-Hive-Push-Key']).toBe('pk_test');
    expect(x.onprogress).not.toBeNull(); // React Native streams text only when a progress handler is set
    x.headersReceived(200);
    x.chunk('retry: 3000\n: connected\n\n');
    x.chunk('event: notification\ndata: ' + item('1').slice(0, 10));
    expect(r.events).toHaveLength(0);
    x.chunk(item('1').slice(10) + '\n\n');
    expect(r.events.map((e) => JSON.parse(e.data).id)).toEqual(['1']);
    x.end();
    expect(r.log).toEqual(['open', 'close']);
  });

  it('reports error answers with their code', () => {
    const x = new FakeXhr();
    const r = recorder();
    connectXhr(() => x, 'u', {}, r.h);
    x.headersReceived(401);
    x.responseText = JSON.stringify({ error: 'expired', code: 'invalid_user_token' });
    x.end();
    expect(r.log).toEqual(['error']);
    expect(r.errors[0]).toMatchObject({ code: 'invalid_user_token', status: 401 });
  });

  it('reports network failures and stops on close()', () => {
    const x = new FakeXhr();
    const r = recorder();
    const c = connectXhr(() => x, 'u', {}, r.h);
    x.onerror?.();
    expect(r.errors[0].code).toBe('network');
    const y = new FakeXhr();
    const r2 = recorder();
    const c2 = connectXhr(() => y, 'u', {}, r2.h);
    c2.close();
    expect(y.aborted).toBe(true);
    y.end();
    expect(r2.log).toEqual([]);
    c.close();
  });
});

describe('connectFetch', () => {
  it('streams a ReadableStream body', async () => {
    const enc = new TextEncoder();
    let push!: (s: string) => void;
    let end!: () => void;
    const body = new ReadableStream<Uint8Array>({
      start(ctrl) {
        push = (s) => ctrl.enqueue(enc.encode(s));
        end = () => ctrl.close();
      },
    });
    const seen: RequestInit[] = [];
    const r = recorder();
    connectFetch(
      async (_u, init) => {
        seen.push(init!);
        return new Response(body, { status: 200 });
      },
      'u',
      { 'X-Hive-Push-Key': 'pk_test' },
      r.h,
    );
    await until(() => r.log.includes('open'));
    expect((seen[0].headers as Record<string, string>)['X-Hive-Push-Key']).toBe('pk_test');
    push(': connected\n\nevent: notification\ndata: ' + item('7') + '\n\n');
    await until(() => r.events.length === 1);
    end();
    await until(() => r.log.includes('close'));
  });

  it('reports error answers', async () => {
    const r = recorder();
    connectFetch(
      async () => new Response(JSON.stringify({ error: 'busy', code: 'over_capacity' }), { status: 503, headers: { 'Retry-After': '30' } }),
      'u',
      {},
      r.h,
    );
    await until(() => r.errors.length === 1);
    expect(r.errors[0]).toMatchObject({ code: 'over_capacity', status: 503, retryAfter: 30 });
  });
});

describe('LiveInbox', () => {
  type Conn = { h: SseHandlers; url: string; closed: boolean };

  function setup(token: { v: string | null } = { v: 't' }) {
    const conns: Conn[] = [];
    const items: unknown[] = [];
    const errors: HivePushError[] = [];
    let connects = 0;
    const live = new LiveInbox({
      connect: (url, _headers, h) => {
        const c: Conn = { h, url, closed: false };
        conns.push(c);
        return { close: () => (c.closed = true) };
      },
      url: () => (token.v ? 'https://h/sdk/v1/stream?user_token=' + token.v : null),
      headers: {},
      onItem: (i) => items.push(i),
      onError: (e) => errors.push(e),
      onConnect: () => connects++,
      initialBackoffMs: 10,
      maxBackoffMs: 40,
      idleTimeoutMs: 60_000,
      random: () => 0,
    });
    return { live, conns, items, errors, connects: () => connects, token };
  }

  it('delivers notification events only', () => {
    const s = setup();
    s.live.start();
    const c = s.conns[0];
    c.h.onOpen();
    c.h.onEvent({ event: 'notification', data: item('1') });
    c.h.onEvent({ event: 'other', data: '{}' });
    c.h.onEvent({ event: 'notification', data: 'not json' });
    expect(s.items).toEqual([JSON.parse(item('1'))]);
    expect(s.connects()).toBe(1);
    s.live.stop();
    expect(c.closed).toBe(true);
  });

  it('reconnects with backoff after drops and retryable errors', async () => {
    const s = setup();
    s.live.start();
    s.conns[0].h.onOpen();
    s.conns[0].h.onClose();
    await until(() => s.conns.length === 2);
    s.conns[1].h.onError(new HivePushError('net', 'network'));
    await until(() => s.conns.length === 3);
    s.conns[2].h.onError(new HivePushError('busy', 'too_many_streams', 429));
    await until(() => s.conns.length === 4);
    s.conns[3].h.onOpen();
    expect(s.connects()).toBe(2);
    expect(s.errors.map((e) => e.code)).toEqual(['network', 'too_many_streams']);
    s.live.stop();
  });

  it('stops on an invalid user token until restart', async () => {
    const s = setup();
    s.live.start();
    s.conns[0].h.onError(new HivePushError('expired', 'invalid_user_token', 401));
    await new Promise((r) => setTimeout(r, 60));
    expect(s.conns).toHaveLength(1);
    s.token.v = 'fresh';
    s.live.restart();
    expect(s.conns).toHaveLength(2);
    expect(s.conns[1].url).toContain('user_token=fresh');
    s.live.stop();
  });

  it('ignores events from a connection it already replaced', async () => {
    const s = setup();
    s.live.start();
    const old = s.conns[0];
    s.live.restart();
    old.h.onEvent({ event: 'notification', data: item('old') });
    old.h.onClose();
    await new Promise((r) => setTimeout(r, 40));
    expect(s.items).toEqual([]);
    expect(s.conns).toHaveLength(2);
    s.live.stop();
  });

  it('reconnects a silent connection', async () => {
    const conns: number[] = [];
    const live = new LiveInbox({
      connect: () => {
        conns.push(1);
        return { close: () => undefined };
      },
      url: () => 'u',
      headers: {},
      onItem: () => undefined,
      initialBackoffMs: 5,
      idleTimeoutMs: 30,
      random: () => 0,
    });
    live.start();
    await until(() => conns.length >= 2);
    live.stop();
  });

  it('reports a missing user token without connecting', () => {
    const s = setup({ v: null });
    s.live.start();
    expect(s.conns).toHaveLength(0);
    expect(s.errors[0].code).toBe('invalid_user_token');
  });
});
