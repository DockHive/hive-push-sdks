/**
 * An error from Hive Push or from the SDK itself.
 *
 * `code` is the stable error code from the API (for example
 * `invalid_user_token`, `platform_not_configured`, `rate_limited`) or one the
 * SDK adds itself: `invalid_options`, `network`, `permission_denied`,
 * `no_token`, `not_registered`, `unsupported`.
 */
export class HivePushError extends Error {
  readonly code: string;
  /** The HTTP status, or 0 when the request never got an answer. */
  readonly status: number;
  /** Seconds the service asked the app to wait before retrying, if it did. */
  readonly retryAfter?: number;

  constructor(message: string, code = 'error', status = 0, retryAfter?: number) {
    super(message);
    this.name = 'HivePushError';
    this.code = code;
    this.status = status;
    if (retryAfter !== undefined) this.retryAfter = retryAfter;
    Object.setPrototypeOf(this, HivePushError.prototype);
  }
}
