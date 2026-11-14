/* Adapters for the React Native peer dependencies. They are loaded lazily so
   the rest of the SDK can be used (and tested) without them. */
import { HivePushError } from './errors';
import type { HivePushStorage, NotificationData, PushMessaging, PushPlatform } from './types';

declare const require: (id: string) => any;

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

function load(name: string, loader: () => any): any {
  try {
    return loader();
  } catch {
    throw new HivePushError(`HivePush: install ${name} (a peer dependency)`, 'invalid_options');
  }
}

/** The current platform from React Native, or null elsewhere. */
export function currentPlatform(): PushPlatform | null {
  try {
    const os = require('react-native').Platform.OS;
    return os === 'ios' || os === 'android' ? os : null;
  } catch {
    return null;
  }
}

/** AsyncStorage from `@react-native-async-storage/async-storage`. */
export function asyncStorage(): HivePushStorage {
  const mod = load('@react-native-async-storage/async-storage', () => require('@react-native-async-storage/async-storage'));
  return (mod && mod.default) || mod;
}

/** Keeps values in memory only. */
export function memoryStorage(): HivePushStorage & { values: Record<string, string> } {
  const values: Record<string, string> = {};
  return {
    values,
    async getItem(k) {
      return k in values ? values[k] : null;
    },
    async setItem(k, v) {
      values[k] = v;
    },
    async removeItem(k) {
      delete values[k];
    },
  };
}

/**
 * {@link PushMessaging} backed by `@react-native-firebase/messaging`: the FCM
 * token on Android and the APNs device token (`getAPNSToken()`) on iOS.
 * Works with the modular API (v22+) and the older namespaced one.
 */
export function firebaseMessaging(opts: { apnsTokenWaitMs?: number } = {}): PushMessaging {
  const mod = load('@react-native-firebase/messaging', () => require('@react-native-firebase/messaging'));
  const modular = typeof mod.getMessaging === 'function';
  const m = modular ? mod.getMessaging() : (mod.default || mod)();
  const call = (name: string, ...args: unknown[]) => (modular ? mod[name](m, ...args) : m[name](...args));
  const wait = opts.apnsTokenWaitMs ?? 5000;

  return {
    async requestPermission() {
      const rn = require('react-native');
      if (rn.Platform.OS === 'android') {
        if (Number(rn.Platform.Version) < 33) return true;
        const perm = (rn.PermissionsAndroid.PERMISSIONS && rn.PermissionsAndroid.PERMISSIONS.POST_NOTIFICATIONS) || 'android.permission.POST_NOTIFICATIONS';
        const res = await rn.PermissionsAndroid.request(perm);
        return res === rn.PermissionsAndroid.RESULTS.GRANTED || res === 'granted';
      }
      const status: number = await call('requestPermission');
      return status >= 1; // AUTHORIZED, PROVISIONAL or EPHEMERAL
    },

    async getToken(platform) {
      if (platform === 'android') return (await call('getToken')) || null;
      try {
        const registered =
          modular && typeof mod.isDeviceRegisteredForRemoteMessages === 'function'
            ? mod.isDeviceRegisteredForRemoteMessages(m)
            : m.isDeviceRegisteredForRemoteMessages;
        if (!registered) await call('registerDeviceForRemoteMessages');
      } catch {
        /* auto-registered */
      }
      // iOS hands the APNs token over shortly after registering; poll briefly.
      const deadline = Date.now() + wait;
      for (;;) {
        const t: string | null = await call('getAPNSToken');
        if (t) return t;
        if (Date.now() > deadline) return null;
        await sleep(250);
      }
    },

    onTokenRefresh(listener) {
      return call('onTokenRefresh', () => listener());
    },

    onNotificationOpened(listener) {
      return call('onNotificationOpenedApp', (msg: { data?: NotificationData } | null) => {
        if (msg) listener(msg.data || {});
      });
    },

    async getInitialNotification() {
      const msg = await call('getInitialNotification');
      return msg ? msg.data || {} : null;
    },
  };
}
