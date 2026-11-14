export interface Call {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: any;
}

export type Responder = (call: Call) => { status: number; body?: unknown; headers?: Record<string, string> } | Promise<never>;

/** A fetch mock that records calls and answers with `respond`. */
export function mockFetch(respond: Responder) {
  const calls: Call[] = [];
  const fn = async (url: string, init: RequestInit = {}) => {
    const call: Call = {
      url,
      method: init.method || 'GET',
      headers: (init.headers as Record<string, string>) || {},
      body: init.body ? JSON.parse(init.body as string) : undefined,
    };
    calls.push(call);
    const r = await respond(call);
    const text = r.body === undefined ? '' : typeof r.body === 'string' ? r.body : JSON.stringify(r.body);
    return new Response(r.status === 204 ? null : text, { status: r.status, headers: r.headers });
  };
  return { fetch: fn, calls };
}

export const tick = (ms = 0) => new Promise<void>((r) => setTimeout(r, ms));

export async function until(cond: () => boolean, timeoutMs = 3000): Promise<void> {
  const end = Date.now() + timeoutMs;
  while (!cond()) {
    if (Date.now() > end) throw new Error('condition not met');
    await tick(5);
  }
}
