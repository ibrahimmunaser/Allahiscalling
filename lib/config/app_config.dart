import 'package:flutter/foundation.dart';

/// Production configuration.
///
/// Values can be supplied at build time with --dart-define, e.g.:
///   flutter build appbundle \
///     --dart-define=PRIVACY_POLICY_URL=https://yourdomain.com/privacy \
///     --dart-define=SUPPORT_EMAIL=support@yourdomain.com
///
/// RELEASE REQUIREMENT: a real, hosted privacy policy URL MUST be configured
/// before shipping to the App Store / Play Store.
///
/// Enforcement layers (see RELEASE_CHECKLIST.md):
///   1. PRIMARY — build time: Android release Gradle tasks validate the
///      dart-defines before packaging (android/app/build.gradle.kts), and
///      CI/iOS builds run `dart run tool/check_release_config.dart` first.
///   2. SECONDARY — runtime: [validateForRelease] throws at startup in a
///      release build that somehow bypassed the build gate, and logs a
///      visible warning in debug builds.
class AppConfig {
  AppConfig._();

  static const String privacyPolicyUrl =
      String.fromEnvironment('PRIVACY_POLICY_URL');

  static const String termsUrl = String.fromEnvironment('TERMS_URL');

  static const String supportEmail = String.fromEnvironment('SUPPORT_EMAIL');

  static const String websiteUrl = String.fromEnvironment('WEBSITE_URL');

  /// Whether [privacyPolicyUrl] points at a real, hosted https policy.
  static bool get hasValidPrivacyPolicyUrl => _isValidHttpsUrl(privacyPolicyUrl);

  static bool _isValidHttpsUrl(String value) {
    if (value.isEmpty) return false;
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.isAbsolute || uri.scheme != 'https') return false;
    if (uri.host.isEmpty || uri.host.contains('example.')) return false;
    return true;
  }

  /// Fails release builds that are missing required production
  /// configuration; logs a clear warning in debug builds.
  ///
  /// This is a deliberate release blocker: both stores require a live
  /// privacy policy URL, so building a release without one is always a
  /// mistake.
  static void validateForRelease() {
    if (hasValidPrivacyPolicyUrl) return;
    if (kReleaseMode) {
      throw StateError(
        'RELEASE CONFIGURATION MISSING: no valid privacy policy URL. '
        'Build with --dart-define=PRIVACY_POLICY_URL=https://... '
        '(see RELEASE_CHECKLIST.md).',
      );
    }
    debugPrint(
      'WARNING [dev only]: PRIVACY_POLICY_URL is not configured. The '
      '"View online version" button is hidden. Release builds will fail '
      'until it is provided via --dart-define.',
    );
  }
}
