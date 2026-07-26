import 'package:allah_invites_you_to_salah/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// Coverage for the privacy-policy-URL safety net.
///
/// [AppConfig.privacyPolicyUrl] itself is a compile-time
/// `String.fromEnvironment` value and cannot vary per test run, so these
/// tests exercise the pure, parameterized validation logic
/// ([AppConfig.isValidHttpsUrl]) directly — every case a real
/// `--dart-define=PRIVACY_POLICY_URL=...` value could take: valid, missing,
/// empty, and malformed.
void main() {
  group('AppConfig.isValidHttpsUrl', () {
    test('a real, hosted https URL is valid', () {
      expect(
        AppConfig.isValidHttpsUrl('https://yourdomain.com/privacy'),
        isTrue,
      );
    });

    test('missing (default empty String.fromEnvironment) is invalid', () {
      expect(AppConfig.isValidHttpsUrl(''), isFalse);
    });

    test('empty string is invalid', () {
      expect(AppConfig.isValidHttpsUrl(''), isFalse);
    });

    test('whitespace-only string is invalid', () {
      expect(AppConfig.isValidHttpsUrl('   '), isFalse);
    });

    test('malformed URL never throws and is invalid', () {
      expect(
        () => AppConfig.isValidHttpsUrl('not a url at all §%^'),
        returnsNormally,
      );
      expect(AppConfig.isValidHttpsUrl('not a url at all §%^'), isFalse);
    });

    test('http (not https) is invalid', () {
      expect(
        AppConfig.isValidHttpsUrl('http://yourdomain.com/privacy'),
        isFalse,
      );
    });

    test('relative path (not absolute) is invalid', () {
      expect(AppConfig.isValidHttpsUrl('/privacy'), isFalse);
    });

    test('example.com placeholder is invalid', () {
      expect(AppConfig.isValidHttpsUrl('https://example.com/privacy'), isFalse);
    });

    test('example.org / any example.* host is invalid', () {
      expect(AppConfig.isValidHttpsUrl('https://example.org/privacy'), isFalse);
      expect(
        AppConfig.isValidHttpsUrl('https://sub.example.net/privacy'),
        isFalse,
      );
    });

    test('https with no host is invalid', () {
      expect(AppConfig.isValidHttpsUrl('https://'), isFalse);
    });

    test('scheme-relative URL (no scheme) is invalid', () {
      expect(AppConfig.isValidHttpsUrl('//yourdomain.com/privacy'), isFalse);
    });
  });

  group('AppConfig.validateForRelease never crashes', () {
    test('returns a bool and never throws, regardless of configuration', () {
      // In the test binary, PRIVACY_POLICY_URL is not set via --dart-define,
      // so this call exercises exactly the "missing configuration" runtime
      // path production code must survive without crashing.
      expect(() => AppConfig.validateForRelease(), returnsNormally);
      expect(AppConfig.validateForRelease(), isA<bool>());
    });

    test('return value matches hasValidPrivacyPolicyUrl', () {
      expect(
        AppConfig.validateForRelease(),
        AppConfig.hasValidPrivacyPolicyUrl,
      );
    });

    test('calling it repeatedly is idempotent and side-effect free', () {
      final first = AppConfig.validateForRelease();
      final second = AppConfig.validateForRelease();
      expect(first, second);
    });
  });
}
