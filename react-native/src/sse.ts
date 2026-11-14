import { errorFromBody, type FetchLike } from './api';
import { HivePushError } from './errors';
import type { InboxItem } from './types';

/** One Server-Sent Event. */
export interface SseEvent {
  /** The event name (`message` when the server named none). */
  event: string;
  data: string;
  id?: string;
}

/** Incremental Server-Sent Events parser: feed it text, it calls `onEvent`. */
export class SseParser {
  private buf = '';
  private event: string | undefined;
  private id: string | undefined;
  private data: string[] = [];
  private lastCR = false;

  constructor(private readonly onEvent: (ev: SseEvent) => void) {}

  push(chunk: string): void {
    let text = chunk;
    // A "\r\n" split across chunks: the "\r" already ended the line.
    if (this.lastCR && text.startsWith('\n')) text = text.slice(1);
    this.lastCR = text.endsWith('\r');
    this.buf += text;
    let start = 0;
    for (let i = 0; i < this.buf.length; i++) {
      const c = this.buf.charCodeAt(i);
      if (c !== 10 && c !== 13) continue;
      this.line(this.buf.slice(start, i));
      if (c === 13 && this.buf.charCodeAt(i + 1) === 10) i++;
      start = i + 1;
    }
    this.buf = this.buf.slice(start);
  }

  private line(line: string): void {
    if (line === '') {
      if (this.data.length) this.onEvent({ event: this.event || 'message', data: this.data.join('\n'), id: this.id });
      this.event = undefined;
      this.data = [];
      return;
    }
    if (line.charCodeAt(0) === 58 /* : */) return;
    const i = line.indexOf(':');
    const field = i < 0 ? line : line.slice(0, i);
    let value = i < 0 ? '' : line.slice(i + 1);
    if (value.charCodeAt(0) === 32) value = value.slice(1);
    if (field === 'event') this.event = value;
    else if (field === 'data') this.data.push(value);
    else if (field === 'id') this.id = value;
  }
}

export interface SseHandlers {
  onOpen(): void;
  onEvent(ev: SseEvent): void;
  /** The connection failed or the server answered with an error. */
  onError(err: HivePushError): void;
  /** The server closed a healthy stream. */
  onClose(): void;
}

export interface SseConnection {
  close(): void;
}

/** Minimal XMLHttpRequest shape (React Native, browsers). */
export interface XhrLike {
  readyState: number;
  status: number;
  responseText: string;
  onreadystatechange: (() => void) | null;
  onprogress: (() => void) | null;
  onerror: (() => void) | null;
  open(method: string, url: string): void;
  setRequestHeader(name: string, value: string): void;
  getResponseHeader(name: string): string | null;
  send(body?: null): void;
  abort(): void;
}

export type XhrFactory = () => XhrLike;

/** Reconnect (to free memory) once this much text has arrived on one connection. */
const MAX_XHR_TEXT = 2 << 20;

/**
 * Server-Sent Events over XMLHttpRequest: React Native's `fetch` cannot stream
 * response bodies, but its XHR delivers text as it arrives.
 */
export function connectXhr(factory: XhrFactory, url: string, headers: Record<string, string>, h: SseHandlers): SseConnection {
  const xhr = factory();
  let seen = 0;
  let opened = false;
  let done = false;
  const parser = new SseParser(h.onEvent);
  const finish = (fn: () => void) => {
    if (done) return;
    done = true;
    fn();
  };
  const drain = () => {
    if (done || xhr.status !== 200) return;
    const text = xhr.responseText || '';
    if (text.length > seen) {
      parser.push(text.slice(seen));
      seen = text.length;
    }
    if (seen > MAX_XHR_TEXT) {
      finish(() => {
        xhr.abort();
        h.onClose();
      });
    }
  };
  xhr.onprogress = drain;
  xhr.onreadystatechange = () => {
    if (done) return;
    if (xhr.readyState >= 2 && !opened && xhr.status === 200) {
      opened = true;
      h.onOpen();
    }
    if (xhr.readyState === 3) drain();
    if (xhr.readyState === 4) {
      if (xhr.status === 200) {
        drain();
        finish(h.onClose);
      } else if (xhr.status === 0) {
        finish(() => h.onError(new HivePushError('Network error talking to Hive Push', 'network')));
      } else {
        finish(() => h.onError(errorFromBody(xhr.status, xhr.responseText || '', xhr.getResponseHeader('Retry-After'))));
      }
    }
  };
  xhr.onerror = () => finish(() => h.onError(new HivePushError('Network error talking to Hive Push', 'network')));
  xhr.open('GET', url);
  for (const k of Object.keys(headers)) xhr.setRequestHeader(k, headers[k]);
  xhr.send(null);
  return {
    close() {
      if (done) return;
      done = true;
      xhr.abort();
    },
  };
}

/** Server-Sent Events over a `fetch` whose response body is a ReadableStream. */
export function connectFetch(fetchImpl: FetchLike, url: string, headers: Record<string, string>, h: SseHandlers): SseConnection {
  const ctrl = typeof AbortController === 'function' ? new AbortController() : null;
  let closed = false;
  const parser = new SseParser(h.onEvent);
  (async () => {
    let res: Response;
    try {
      res = await fetchImpl(url, { method: 'GET', headers, signal: ctrl ? ctrl.signal : undefined });
    } catch {
      if (!closed) h.onError(new HivePushError('Network error talking to Hive Push', 'network'));
      return;
    }
    if (closed) return;
    if (res.status !== 200) {
      let text = '';
      try {
        text = await res.text();
      } catch {
        /* ignore */
      }
      if (!closed) h.onError(errorFromBody(res.status, text, res.headers.get('Retry-After')));
      return;
    }
    const body = res.body as ReadableStream<Uint8Array> | null;
    if (!body || typeof body.getReader !== 'function') {
      h.onError(new HivePushError('This fetch cannot stream responses', 'unsupported'));
      return;
    }
    h.onOpen();
    const reader = body.getReader();
    const decoder = new TextDecoder();
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (closed) return;
        if (done) break;
        if (value) parser.push(decoder.decode(value, { stream: true }));
      }
    } catch {
      if (!closed) h.onError(new HivePushError('Network error talking to Hive Push', 'network'));
      return;
    }
    if (!closed) h.onClose();
  })();
  return {
    close() {
      closed = true;
      if (ctrl) ctrl.abort();
    },
  };
}

export type SseConnect = (url: string, headers: Record<string, string>, h: SseHandlers) => SseConnection;

/** XHR when available (React Native), otherwise a streaming fetch. */
export function defaultConnect(fetchImpl?: FetchLike): SseConnect {
  const X = (globalThis as { XMLHttpRequest?: new () => XhrLike }).XMLHttpRequest;
  if (typeof X === 'function') return (url, headers, h) => connectXhr(() => new X(), url, headers, h);
  const f = fetchImpl || (typeof fetch === 'function' ? (fetch.bind(globalThis) as FetchLike) : undefined);
  if (!f) throw new HivePushError('No XMLHttpRequest or fetch available for the live inbox', 'unsupported');
  return (url, headers, h) => connectFetch(f, url, headers, h);
}

export interface LiveInboxOptions {
  connect: SseConnect;
  url: () => string | null;
  headers: Record<string, string>;
  onItem: (item: InboxItem) => void;
  /** Every error, including ones that are retried. */
  onError?: (err: HivePushError) => void;
  /** Called each time the live connection opens: re-read the inbox to catch up. */
  onConnect?: () => void;
  initialBackoffMs?: number;
  maxBackoffMs?: number;
  /** The service sends a keep-alive every 25 s; silence this long reconnects. */
  idleTimeoutMs?: number;
  random?: () => number;
}

/** True for errors that retrying cannot fix (bad key or user token, disabled app). */
export function isFatal(err: HivePushError): boolean {
  return err.status === 401 || err.status === 404 || err.code === 'origin_not_allowed' || err.code === 'app_disabled';
}

/**
 * The live inbox: connects, parses `notification` events and reconnects with
 * backoff (1 s doubling to 30 s, plus jitter). Fatal errors stop it until
 * `restart()`.
 */
export class LiveInbox {
  private conn: SseConnection | null = null;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private idle: ReturnType<typeof setTimeout> | null = null;
  private delay: number;
  private stopped = false;
  private gen = 0;

  constructor(private readonly o: LiveInboxOptions) {
    this.delay = o.initialBackoffMs ?? 1000;
  }

  start(): void {
    this.stopped = false;
    this.open();
  }

  /** Reconnects now (for example after a new user token). */
  restart(): void {
    if (this.stopped) return;
    this.teardown();
    this.delay = this.o.initialBackoffMs ?? 1000;
    this.open();
  }

  stop(): void {
    this.stopped = true;
    this.teardown();
  }

  private teardown(): void {
    this.gen++;
    if (this.timer) clearTimeout(this.timer);
    if (this.idle) clearTimeout(this.idle);
    this.timer = this.idle = null;
    if (this.conn) this.conn.close();
    this.conn = null;
  }

  private report(err: HivePushError): void {
    if (!this.o.onError) return;
    try {
      this.o.onError(err);
    } catch {
      /* ignore */
    }
  }

  private open(): void {
    if (this.stopped) return;
    const url = this.o.url();
    if (!url) {
      this.report(new HivePushError('Call setUser(userId, token) before using the inbox', 'invalid_user_token'));
      return;
    }
    const gen = ++this.gen;
    const live = () => gen === this.gen && !this.stopped;
    const touch = () => {
      if (this.idle) clearTimeout(this.idle);
      this.idle = setTimeout(() => {
        if (!live()) return;
        this.retry(gen);
      }, this.o.idleTimeoutMs ?? 70000);
    };
    touch();
    this.conn = this.o.connect(url, this.o.headers, {
      onOpen: () => {
        if (!live()) return;
        this.delay = this.o.initialBackoffMs ?? 1000;
        touch();
        if (this.o.onConnect) {
          try {
            this.o.onConnect();
          } catch {
            /* ignore */
          }
        }
      },
      onEvent: (ev) => {
        if (!live()) return;
        touch();
        if (ev.event !== 'notification') return;
        let item: InboxItem;
        try {
          item = JSON.parse(ev.data);
        } catch {
          return;
        }
        try {
          this.o.onItem(item);
        } catch (e) {
          setTimeout(() => {
            throw e;
          });
        }
      },
      onError: (err) => {
        if (!live()) return;
        this.report(err);
        if (isFatal(err)) {
          this.teardown();
          return;
        }
        this.retry(gen, err.retryAfter);
      },
      onClose: () => {
        if (!live()) return;
        this.retry(gen);
      },
    });
  }

  private retry(gen: number, retryAfterSec?: number): void {
    if (gen !== this.gen || this.stopped) return;
    this.teardown();
    const rand = this.o.random || Math.random;
    let wait = this.delay + Math.floor(rand() * 500);
    if (retryAfterSec && retryAfterSec * 1000 > wait) wait = retryAfterSec * 1000;
    this.delay = Math.min(this.delay * 2, this.o.maxBackoffMs ?? 30000);
    this.timer = setTimeout(() => this.open(), wait);
  }
}
