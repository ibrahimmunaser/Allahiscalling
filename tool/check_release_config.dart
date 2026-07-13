// Pre-build release configuration gate for CI and iOS builds.
//
// Android release builds are already validated inside Gradle
// (android/app/build.gradle.kts), which fails before packaging. iOS/Xcode
// has no equivalent hook for --dart-define values, so CI must run this
// script BEFORE `flutter build ipa` (and may also run it before Android
// builds as a first line of defense):
//
//   dart run tool/check_release_config.dart
//
// Values are read from environment variables (set them in CI) or from
// --key=value arguments:
//
//   PRIVACY_POLICY_URL   required, https, not example.*
//   SUPPORT_EMAIL        required, must contain @
//
// Exit code 0 = configuration valid; 1 = invalid (build must not proceed).
//
// The in-app runtime check (lib/config/app_config.dart) remains as a
// secondary safeguard, but this script is the primary, pre-packaging gate.

import 'dart:io';

void main(List<String> args) {
  final values = <String, String>{
    for (final key in ['PRIVACY_POLICY_URL', 'SUPPORT_EMAIL'])
      key: Platform.environment[key] ?? '',
  };
  for (final arg in args) {
    if (!arg.startsWith('--')) continue;
    final idx = arg.indexOf('=');
    if (idx < 0) continue;
    final key = arg
        .substring(2, idx)
        .replaceAll('-', '_')
        .toUpperCase();
    values[key] = arg.substring(idx + 1);
  }

  final problems = <String>[];

  final privacyUrl = values['PRIVACY_POLICY_URL'] ?? '';
  final uri = Uri.tryParse(privacyUrl);
  if (privacyUrl.isEmpty) {
    problems.add('PRIVACY_POLICY_URL is missing.');
  } else if (uri == null ||
      !uri.isAbsolute ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.host.contains('example.')) {
    problems.add(
        'PRIVACY_POLICY_URL is not a valid production https URL: $privacyUrl');
  }

  final supportEmail = values['SUPPORT_EMAIL'] ?? '';
  if (supportEmail.isEmpty || !supportEmail.contains('@')) {
    problems.add('SUPPORT_EMAIL is missing or invalid.');
  }

  if (problems.isNotEmpty) {
    stderr.writeln('RELEASE CONFIGURATION INVALID — do not build/package:');
    for (final p in problems) {
      stderr.writeln('  - $p');
    }
    stderr.writeln('');
    stderr.writeln('Set the values as environment variables or pass them:');
    stderr.writeln('  dart run tool/check_release_config.dart '
        '--privacy-policy-url=https://yourdomain.com/privacy '
        '--support-email=support@yourdomain.com');
    stderr.writeln('Then build with the SAME values via --dart-define '
        '(see RELEASE_CHECKLIST.md).');
    exit(1);
  }

  stdout.writeln('Release configuration OK.');
}
