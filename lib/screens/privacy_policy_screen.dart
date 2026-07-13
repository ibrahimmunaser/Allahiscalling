import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';

/// In-app privacy policy.
///
/// The text below truthfully describes the app's actual behavior. The
/// "View online version" button appears only when a production policy URL
/// has been configured (see [AppConfig.privacyPolicyUrl]); it is never
/// shown pointing at a placeholder and never fails silently.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  static const _sections = <(String, String)>[
    (
      'Your location stays on your device',
      'Your coordinates are used only to calculate prayer times locally on '
          'your device. They are never uploaded to any server owned by this '
          'app, and there are no app accounts.',
    ),
    (
      'City search',
      'City search works from an offline database bundled with the app. If '
          'you choose "Search online", your search text is sent to your '
          'platform\'s geocoding service (Google on Android, Apple on iOS) '
          'to find coordinates. Successful results are cached on your device.',
    ),
    (
      'Notifications',
      'All prayer reminders are local notifications scheduled on your '
          'device. No push-notification service is used.',
    ),
    (
      'Prayer completion',
      'If you record that you completed a prayer, that record is stored only '
          'on your device.',
    ),
    (
      'Analytics and ads',
      'This app contains no analytics, no tracking, and no advertising.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy Policy')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          for (final (title, body) in _sections) ...[
            Text(
              title,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(body, style: const TextStyle(height: 1.5)),
            const SizedBox(height: 20),
          ],
          if (AppConfig.hasValidPrivacyPolicyUrl)
            OutlinedButton.icon(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                final uri = Uri.parse(AppConfig.privacyPolicyUrl);
                try {
                  final ok = await launchUrl(uri,
                      mode: LaunchMode.externalApplication);
                  if (!ok) throw Exception('launchUrl returned false');
                } catch (_) {
                  messenger.showSnackBar(const SnackBar(
                      content:
                          Text('Could not open the privacy policy link.')));
                }
              },
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('View online version'),
            )
          else if (kDebugMode)
            const Card(
              color: Color(0xFFFFF3E0),
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'DEV WARNING: PRIVACY_POLICY_URL is not configured. '
                  'Release builds fail until it is provided via '
                  '--dart-define (see RELEASE_CHECKLIST.md).',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
