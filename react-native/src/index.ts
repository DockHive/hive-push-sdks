import { VERSION } from './api';
import { HivePushClient, notificationIdFrom, type InitOptions } from './client';
import { HivePushError } from './errors';

let current: HivePushClient | null = null;

/**
 * Hive Push for React Native.
 *
 * ```ts
 * const push = HivePush.init({ key: 'pk_...', region: 'global-1' });
 * await push.requestPermission();
 * await push.register();
 * ```
 */
export const HivePush = {
  VERSION,
  HivePushError,
  /** Sets up Hive Push; call it once at startup. Also available later as `HivePush.instance()`. */
  init(opts: InitOptions): HivePushClient {
    if (current) current.dispose();
    current = new HivePushClient(opts);
    return current;
  },
  /** The client made by the last `init` call. */
  instance(): HivePushClient {
    if (!current) throw new HivePushError('Call HivePush.init(...) first', 'invalid_options');
    return current;
  },
  notificationIdFrom,
};

export default HivePush;
export { HivePushClient, notificationIdFrom, HivePushError, VERSION };
export type { InitOptions, OnMessageOptions, HivePushInbox } from './client';
export { HivePushApi, baseURL } from './api';
export type { FetchLike, RegisterDeviceParams, UpdateDeviceParams } from './api';
export { SseParser, LiveInbox, connectFetch, connectXhr, defaultConnect } from './sse';
export type { SseEvent, SseConnect, SseConnection, SseHandlers, XhrLike } from './sse';
export { firebaseMessaging, asyncStorage, memoryStorage } from './native';
export * from './types';
