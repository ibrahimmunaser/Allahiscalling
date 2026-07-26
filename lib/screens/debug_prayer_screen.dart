import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../state/app_controller.dart';
import '../utils/formatting.dart';

/// Development/testing screen: raw view of device state, settings,
/// calculated times, permissions, and the pending notification queue.
class DebugPrayerScreen extends StatefulWidget {
  const DebugPrayerScreen({super.key});

  @override
  State<DebugPrayerScreen> createState() => _DebugPrayerScreenState();
}

class _DebugPrayerScreenState extends State<DebugPrayerScreen> {
  String _pendingNotifications = 'Loading...';
  String _permissions = 'Loading...';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final controller = context.read<AppController>();

    try {
      final pending =
          await controller.notificationService.pendingNotifications();
      _pendingNotifications =
          pending.isEmpty
              ? 'No pending notifications'
              : [
                'Pending count: ${pending.length}',
                ...pending.map((p) => 'ID ${p.id}: ${p.title} / ${p.body}'),
              ].join('\n');
    } catch (e) {
      _pendingNotifications = 'Error: $e';
    }

    try {
      final notificationsEnabled =
          await controller.notificationService.areNotificationsEnabled();
      final exactAlarms =
          await controller.notificationService.canScheduleExactAlarms();
      final locationPermission = await Geolocator.checkPermission();
      _permissions = [
        'Notifications enabled: $notificationsEnabled',
        'Exact alarms allowed: $exactAlarms',
        'Location permission: ${locationPermission.name}',
      ].join('\n');
    } catch (e) {
      _permissions = 'Error: $e';
    }

    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final settings = controller.settings;
    final scheduled = controller.scheduledReminders;
    final stats = controller.schedulingStats;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _DebugSection(
            title: 'Device',
            content: [
              'Device time: ${DateTime.now()}',
              'Device time (user zone): ${controller.nowInUserZone()}',
              'Timezone (settings): ${settings.timezone ?? "not set"}',
              'Last known timezone: ${controller.repository.loadLastKnownTimezone() ?? "none"}',
            ].join('\n'),
          ),
          _DebugSection(
            title: 'Location',
            content: [
              'Latitude: ${settings.latitude ?? "not set"}',
              'Longitude: ${settings.longitude ?? "not set"}',
              'Label: ${settings.locationLabel ?? "none"}',
              'Source: ${settings.locationSource.displayName}',
            ].join('\n'),
          ),
          _DebugSection(
            title: 'Calculation',
            content: [
              'Method: ${settings.calculationMethod.displayName}',
              'Asr: ${settings.asrMethod.displayName}',
              'High latitude: ${settings.highLatitudeRule.displayName}',
              'Adjustments: ${settings.manualAdjustments.map((k, v) => MapEntry(k.displayName, v))}',
              'Last calculation: ${controller.lastSchedulingTime ?? "never"}',
            ].join('\n'),
          ),
          _DebugSection(
            title: 'Scheduling health',
            content: [
              'Last successful scheduling: ${controller.lastSchedulingTime ?? "never"}',
              'Last scheduled prayer: ${stats.lastPrimaryAt?.toLocal() ?? "none"}',
              'Primary reminders: ${stats.primary}',
              'Follow-ups: ${stats.followUps}',
              'Snoozes: ${stats.snoozes}',
              'Persisted total: ${scheduled.length}',
              'Days of primary coverage: ${stats.daysOfCoverage.toStringAsFixed(1)}',
            ].join('\n'),
          ),
          _DebugSection(
            title: "Today's prayer times",
            content:
                controller.today == null
                    ? 'Not calculated'
                    : controller.today!.orderedEntries
                        .map(
                          (e) =>
                              '${e.key.displayName}: ${e.value} (${formatTime(e.value)})',
                        )
                        .join('\n'),
          ),
          _DebugSection(
            title: 'Next scheduled reminder',
            content:
                controller.nextReminder == null
                    ? 'None'
                    : 'ID ${controller.nextReminder!.notificationId}: '
                        '${controller.nextReminder!.prayer.displayName} at '
                        '${controller.nextReminder!.scheduledAt.toLocal()}',
          ),
          _DebugSection(
            title: 'Persisted scheduled IDs (${scheduled.length})',
            content:
                scheduled.isEmpty
                    ? 'None'
                    : scheduled
                        .map(
                          (r) =>
                              'ID ${r.notificationId}: ${r.prayer.displayName} at ${r.scheduledAt.toLocal()}',
                        )
                        .join('\n'),
          ),
          _DebugSection(
            title: 'Pending notifications (plugin)',
            content: _pendingNotifications,
          ),
          _DebugSection(title: 'Permissions', content: _permissions),
        ],
      ),
    );
  }
}

class _DebugSection extends StatelessWidget {
  final String title;
  final String content;

  const _DebugSection({required this.title, required this.content});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            ),
            const SizedBox(height: 6),
            SelectableText(
              content,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
