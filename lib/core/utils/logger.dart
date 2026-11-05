import 'app_logger.dart';

/// Centralized logger that feeds into AppLogger for in-app crash tracing & logs.
class Log {
  Log._();

  /// Enable/disable verbose debug logging
  static bool verbose = true;

  /// General info log
  static void i(String tag, String message) {
    AppLogger.i(tag, message);
  }

  /// Success log (with ✅)
  static void success(String message) {
    AppLogger.i('Success', '✅ $message');
  }

  /// Warning log (with ⚠️)
  static void w(String tag, String message) {
    AppLogger.w(tag, message);
  }

  /// Error log (with ❌)
  static void e(String tag, String message, [Object? error, StackTrace? stack]) {
    AppLogger.e(tag, message, error, stack);
  }

  /// Debug-only detailed/verbose log
  static void d(String tag, String message) {
    if (verbose) {
      AppLogger.d(tag, message);
    }
  }
}
