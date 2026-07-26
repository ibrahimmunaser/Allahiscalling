import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../services/diagnostics_log.dart';
import '../state/app_controller.dart';

/// Beta diagnostics report.
///
/// Privacy contract — the report deliberately NEVER includes:
///   - GPS coordinates (only the location *source type* and timezone),
///   - prayer completion or response history,
///   - personal identifiers or email addresses.
/// Nothing is transmitted automatically; the user copies the text and
/// shares it manually if and when they choose to.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  String? _report;

  @override
  void initState() {
    super.initState();
    _buildReport();
  }

  Future<void> _buildReport() async {
    final controller = context.read<AppController>();
    final lines = <String>[];

    lines.add('=== Allah Invites You to Salah — diagnostics ===');
    lines.add('Generated: ${DateTime.now().toIso8601String()}');
    lines.add('');

    // App + device.
    try {
      final info = await PackageInfo.fromPlatform();
      lines.add('App version: ${info.version} (${info.buildNumber})');
    } catch (e) {
      lines.add('App version: unavailable ($e)');
    }
    lines.add('Build mode: ${kReleaseMode ? "release" : "debug/profile"}');
    try {
      if (!kIsWeb && Platform.isAndroid) {
        final android = await DeviceInfoPlugin().androidInfo;
        lines.add(
          'OS: Android ${android.version.release} '
          '(SDK ${android.version.sdkInt})',
        );
        lines.add('Device: ${android.manufacturer} ${android.model}');
        lines.add(
          android.version.sdkInt >= 34
              ? 'Full-screen intent: special access required on this Android '
                  'version — state not queryable in-app; verify under '
                  'Settings > Apps > Special app access.'
              : 'Full-screen intent: granted at install on this Android '
                  'version.',
        );
      } else if (!kIsWeb && Platform.isIOS) {
        final ios = await DeviceInfoPlugin().iosInfo;
        lines.add('OS: iOS ${ios.systemVersion}');
        lines.add('Device: Apple ${ios.utsname.machine}');
      }
    } catch (e) {
      lines.add('Device info: unavailable ($e)');
    }
    lines.add('');

    // Configuration (no coordinates — privacy).
    final settings = controller.settings;
    lines.add('Timezone (selected): ${settings.timezone ?? "not set"}');
    lines.add(
      'Timezone (device): ${DateTime.now().timeZoneName} '
      '(UTC${DateTime.now().timeZoneOffset.isNegative ? "" : "+"}'
      '${DateTime.now().timeZoneOffset.inHours})',
    );
    lines.add(
      'Location source: ${settings.locationSource.name} '
      '(coordinates withheld from this report)',
    );
    lines.add('Calculation method: ${settings.calculationMethod.name}');
    lines.add('Asr method: ${settings.asrMethod.name}');
    lines.add('Notifications enabled: ${settings.notificationsEnabled}');
    lines.add('Notification permission: ${controller.notificationsPermitted}');
    lines.add('Exact alarms available: ${controller.exactAlarmsAvailable}');
    lines.add('');

    // Scheduling health.
    final stats = controller.schedulingStats;
    lines.add(
      'Last successful scheduling: '
      '${controller.lastSchedulingTime?.toIso8601String() ?? "never"}',
    );
    lines.add(
      'Next primary reminder: '
      '${controller.nextReminder?.scheduledAt.toIso8601String() ?? "none"}',
    );
    lines.add(
      'Last primary reminder: '
      '${stats.lastPrimaryAt?.toIso8601String() ?? "none"}',
    );
    lines.add('Primary reminders: ${stats.primary}');
    lines.add('Follow-ups: ${stats.followUps}');
    lines.add('Snoozes: ${stats.snoozes}');
    lines.add(
      'Days of primary coverage: '
      '${stats.daysOfCoverage.toStringAsFixed(1)}',
    );
    try {
      final pending =
          await controller.notificationService.pendingNotifications();
      lines.add('OS pending notifications: ${pending.length}');
    } catch (e) {
      lines.add('OS pending notifications: unavailable ($e)');
    }
    lines.add('');

    // Recent errors (source + message only; never user data).
    final errors = DiagnosticsLog.load(controller.repository.prefs);
    if (errors.isEmpty) {
      lines.add('Recent errors: none recorded');
    } else {
      lines.add('Recent errors (${errors.length}, oldest first):');
      for (final e in errors) {
        lines.add('  [${e['at']}] ${e['source']}: ${e['error']}');
      }
    }
    lines.add('');
    lines.add(
      'This report contains no location coordinates, no prayer '
      'history, and no personal identifiers.',
    );

    if (mounted) setState(() => _report = lines.join('\n'));
  }

  Future<void> _copy() async {
    final report = _report;
    if (report == null) return;
    await Clipboard.setData(ClipboardData(text: report));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Diagnostics copied to clipboard.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics (beta)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy report',
            onPressed: _report == null ? null : _copy,
          ),
        ],
      ),
      body:
          _report == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        'Share this report with the beta team when reporting '
                        'missed, late, duplicate, or stopped reminders. It '
                        'includes no location coordinates, prayer history, or '
                        'personal identifiers.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    _report!,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _copy,
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy report'),
                  ),
                ],
              ),
    );
  }
}
