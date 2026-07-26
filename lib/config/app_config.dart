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
///      CI/iOS builds run `dart run tool/check_release_config.dart` first
///      (exits non-zero — the build/package step must not proceed).
///   2. SECONDARY — runtime: [validateForRelease] NEVER throws or crashes
///      the app, in any build mode. If the build gate above was somehow
///      bypassed, a missing/invalid URL degrades gracefully at runtime
///      (the "View online version" button simply stays hidden, see
///      [hasValidPrivacyPolicyUrl] and `privacy_policy_screen.dart`) and is
///      reported via [debugPrint] plus, once storage is available, an entry
///      in `DiagnosticsLog` — never a hard crash. A crash here would be far
///      worse for users already running a shipped build than a hidden
///      button.
class AppConfig {
  AppConfig._();

  static const String privacyPolicyUrl = String.fromEnvironment(
    'PRIVACY_POLICY_URL',
  );

  static const String termsUrl = String.fromEnvironment('TERMS_URL');

  static const String supportEmail = String.fromEnvironment('SUPPORT_EMAIL');

  static const String websiteUrl = String.fromEnvironment('WEBSITE_URL');

  /// Whether [privacyPolicyUrl] points at a real, hosted https policy.
  static bool get hasValidPrivacyPolicyUrl => isValidHttpsUrl(privacyPolicyUrl);

  /// Pure validation, exposed (not private) so tests can exercise every
  /// case — missing, empty, malformed, placeholder, and valid — without
  /// depending on compile-time `--dart-define` values, which
  /// [privacyPolicyUrl] itself cannot vary per test run. Never throws: an
  /// unparsable [value] is simply invalid, not an exception.
  static bool isValidHttpsUrl(String value) {
    if (value.isEmpty) return false;
    final Uri? uri;
    try {
      uri = Uri.tryParse(value);
    } catch (_) {
      return false;
    }
    if (uri == null || !uri.isAbsolute || uri.scheme != 'https') return false;
    if (uri.host.isEmpty || uri.host.contains('example.')) return false;
    return true;
  }

  /// Logs (never throws — see class docs) whether required production
  /// configuration is present, and returns `true` when it is valid.
  ///
  /// The actual release BLOCKER is [tool/check_release_config.dart] (plus
  /// the Android Gradle check) run before packaging — see
  /// RELEASE_CHECKLIST.md. This method is only a defense-in-depth runtime
  /// signal for whichever build slipped through that gate; it must degrade
  /// gracefully, not crash a build already in a user's hands.
  static bool validateForRelease() {
    if (hasValidPrivacyPolicyUrl) return true;
    if (kReleaseMode) {
      // Deliberately NOT a throw: crashing a shipped release build over a
      // hidden "View online version" button would be strictly worse for
      // users than the degraded (but functional) privacy policy screen.
      debugPrint(
        'RELEASE CONFIGURATION WARNING: PRIVACY_POLICY_URL is missing or '
        'invalid in this release build. This should have been caught by '
        'tool/check_release_config.dart before packaging — see '
        'RELEASE_CHECKLIST.md. The app will continue to run; the '
        '"View online version" button stays hidden.',
      );
    } else {
      debugPrint(
        'WARNING [dev only]: PRIVACY_POLICY_URL is not configured. The '
        '"View online version" button is hidden. Release builds must run '
        '`dart run tool/check_release_config.dart` before packaging.',
      );
    }
    return false;
  }
}
