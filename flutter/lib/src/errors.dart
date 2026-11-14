/// An error from Hive Push or from the SDK itself.
///
/// [code] is the stable error code from the API (for example
/// `invalid_user_token`, `platform_not_configured`, `rate_limited`) or one the
/// SDK adds itself: `invalid_options`, `network`, `permission_denied`,
/// `no_token`, `not_registered`.
class HivePushException implements Exception {
  HivePushException(this.message, {this.code = 'error', this.status = 0, this.retryAfter});

  /// A readable description of the problem.
  final String message;

  /// The stable error code.
  final String code;

  /// The HTTP status, or 0 when the request never got an answer.
  final int status;

  /// How long the service asked the app to wait before retrying, when it did.
  final Duration? retryAfter;

  @override
  String toString() => 'HivePushException($code${status > 0 ? ', HTTP $status' : ''}): $message';
}
