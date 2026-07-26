import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../models/prayer_settings.dart';
import '../models/salah_prayer.dart';
import '../state/app_controller.dart';
import '../utils/app_strings.dart';
import '../utils/app_theme.dart';
import '../utils/formatting.dart';
import '../widgets/location_feedback.dart';
import 'diagnostics_screen.dart';
import 'incoming_salah_screen.dart';
import 'manual_location_screen.dart';
import 'privacy_policy_screen.dart';

String _alarmKitSubtitle(AppController controller) {
  switch (controller.alarmKitAuthStatus) {
    case 'authorized':
      return 'Prominent prayer alarms are enabled';
    case 'denied':
      return 'Permission denied — tap Open Settings below';
    case 'notDetermined':
      return 'Tap to allow prominent prayer alarms (iOS 26+)';
    default:
      return 'AlarmKit unavailable on this device';
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final settings = controller.settings;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionHeader('Location'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.location_on_outlined),
                  title: Text(settings.locationLabel ?? 'Not set'),
                  subtitle: Text(settings.locationSource.displayName),
                ),
                if (settings.hasLocation)
                  ListTile(
                    leading: const Icon(Icons.explore_outlined),
                    title: Text(
                      '${settings.latitude!.toStringAsFixed(4)}, ${settings.longitude!.toStringAsFixed(4)}',
                    ),
                    subtitle: const Text('Latitude, longitude'),
                  ),
                ListTile(
                  leading: const Icon(Icons.public),
                  title: Text(settings.timezone ?? 'Timezone not detected'),
                  subtitle: const Text('Timezone'),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextButton.icon(
                          onPressed: () async {
                            final status =
                                await controller.useCurrentLocation();
                            if (!context.mounted) return;
                            showLocationStatusFeedback(context, status);
                          },
                          icon: const Icon(Icons.my_location, size: 18),
                          label: const Text('Use current location'),
                        ),
                      ),
                      Expanded(
                        child: TextButton.icon(
                          onPressed:
                              () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const ManualLocationScreen(),
                                ),
                              ),
                          icon: const Icon(
                            Icons.edit_location_alt_outlined,
                            size: 18,
                          ),
                          label: const Text('Set manually'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SectionHeader('Calculation'),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('Calculation Method'),
                  subtitle: Text(settings.calculationMethod.displayName),
                  trailing: const Icon(Icons.chevron_right),
                  onTap:
                      () => _pickEnum<CalculationMethodOption>(
                        context: context,
                        title: 'Calculation Method',
                        values: CalculationMethodOption.values,
                        selected: settings.calculationMethod,
                        labelOf: (v) => v.displayName,
                        onSelected:
                            (v) => controller.updateSettings(
                              settings.copyWith(calculationMethod: v),
                            ),
                      ),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('Asr Method'),
                  subtitle: Text(settings.asrMethod.displayName),
                  trailing: const Icon(Icons.chevron_right),
                  onTap:
                      () => _pickEnum<AsrMethod>(
                        context: context,
                        title: 'Asr Method',
                        values: AsrMethod.values,
                        selected: settings.asrMethod,
                        labelOf: (v) => v.displayName,
                        onSelected:
                            (v) => controller.updateSettings(
                              settings.copyWith(asrMethod: v),
                            ),
                      ),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('High-latitude rule'),
                  subtitle: Text(settings.highLatitudeRule.displayName),
                  trailing: const Icon(Icons.chevron_right),
                  onTap:
                      () => _pickEnum<HighLatitudeRuleOption>(
                        context: context,
                        title: 'High-latitude rule',
                        values: HighLatitudeRuleOption.values,
                        selected: settings.highLatitudeRule,
                        labelOf: (v) => v.displayName,
                        onSelected:
                            (v) => controller.updateSettings(
                              settings.copyWith(highLatitudeRule: v),
                            ),
                      ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Prayer times may vary by local masjid. '
                        'Use manual adjustments if needed.',
                        style: TextStyle(fontSize: 13, color: Colors.grey),
                      ),
                      if (settings.calculationMethod ==
                          CalculationMethodOption.ummAlQura) ...[
                        const SizedBox(height: 6),
                        const Text(
                          'Umm al-Qura note: during Ramadan, Isha is '
                          'traditionally observed 90 min after Maghrib — '
                          'add +30 min to Isha via "Match my local masjid" '
                          'if your masjid follows this.',
                          style: TextStyle(fontSize: 12, color: Colors.orange),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SectionHeader('Match my local masjid'),
          Card(
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    'Masjids often adjust athan times by a few minutes. '
                    'Compare with your masjid\'s timetable and offset each '
                    'prayer here (in minutes).',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                ),
                ...SalahPrayer.values.map((prayer) {
                  final value = settings.adjustmentFor(prayer);
                  return ListTile(
                    title: Text(prayer.displayName),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed:
                              value <= -60
                                  ? null
                                  : () => controller.setManualAdjustment(
                                    prayer,
                                    value - 1,
                                  ),
                        ),
                        SizedBox(
                          width: 44,
                          child: Text(
                            value > 0 ? '+$value' : '$value',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed:
                              value >= 60
                                  ? null
                                  : () => controller.setManualAdjustment(
                                    prayer,
                                    value + 1,
                                  ),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SectionHeader('Reminders'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Prayer reminders'),
                  subtitle: const Text(
                    'Receive a reminder when each prayer enters',
                  ),
                  value: settings.notificationsEnabled,
                  onChanged:
                      (v) => controller.updateSettings(
                        settings.copyWith(notificationsEnabled: v),
                      ),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('Snooze duration'),
                  subtitle: Text('${settings.snoozeMinutes} minutes'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap:
                      () => _pickEnum<int>(
                        context: context,
                        title: 'Snooze duration',
                        values: const [5, 10, 15, 20, 30],
                        selected: settings.snoozeMinutes,
                        labelOf: (v) => '$v minutes',
                        onSelected:
                            (v) => controller.updateSettings(
                              settings.copyWith(snoozeMinutes: v),
                            ),
                      ),
                ),
                if (!controller.notificationsPermitted) ...[
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(
                      Icons.notifications_off_outlined,
                      color: Colors.orange,
                    ),
                    title: const Text('Notifications are not permitted'),
                    subtitle: const Text(
                      'Tap to request notification permission',
                    ),
                    onTap: controller.requestNotificationPermission,
                  ),
                ],
                if (controller.alarmKitAvailable) ...[
                  const Divider(height: 1),
                  ListTile(
                    leading: Icon(
                      controller.alarmKitAuthorized
                          ? Icons.alarm_on_outlined
                          : Icons.alarm_off_outlined,
                      color:
                          controller.alarmKitAuthorized ? null : Colors.orange,
                    ),
                    title: const Text('Prayer alarms (AlarmKit)'),
                    subtitle: Text(_alarmKitSubtitle(controller)),
                    onTap: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      if (controller.alarmKitAuthStatus == 'denied') {
                        await controller.openAlarmKitSettings();
                        return;
                      }
                      if (controller.alarmKitAuthorized) return;
                      final status =
                          await controller.requestAlarmKitPermission();
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(
                            status == 'authorized'
                                ? 'Prayer alarms enabled.'
                                : status == 'denied'
                                ? 'Alarm permission denied. Open Settings to enable.'
                                : 'Alarm permission: $status',
                          ),
                        ),
                      );
                    },
                  ),
                  if (controller.alarmKitAuthStatus == 'denied') ...[
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.settings_outlined),
                      title: const Text('Open Settings for alarm permission'),
                      onTap: controller.openAlarmKitSettings,
                    ),
                  ],
                ],
                if (!controller.exactAlarmsAvailable) ...[
                  const Divider(height: 1),
                  const ListTile(
                    leading: Icon(
                      Icons.schedule_outlined,
                      color: Colors.orange,
                    ),
                    title: Text('Reminder timing is approximate'),
                    subtitle: Text(
                      'Exact alarms are unavailable on this device, so '
                      'reminders may arrive a few minutes late. Allow '
                      '"Alarms & reminders" in system settings for '
                      'on-the-minute timing.',
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SectionHeader('Display'),
          Card(
            child: ListTile(
              title: const Text('Hijri Date Adjustment'),
              subtitle: const Text(
                'Adjust the displayed Hijri date to match your local '
                'moon-sighting authority.',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed:
                        settings.hijriAdjustmentDays <= -2
                            ? null
                            : () => controller.updateSettings(
                              settings.copyWith(
                                hijriAdjustmentDays:
                                    settings.hijriAdjustmentDays - 1,
                              ),
                            ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      settings.hijriAdjustmentDays > 0
                          ? '+${settings.hijriAdjustmentDays}'
                          : '${settings.hijriAdjustmentDays}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed:
                        settings.hijriAdjustmentDays >= 2
                            ? null
                            : () => controller.updateSettings(
                              settings.copyWith(
                                hijriAdjustmentDays:
                                    settings.hijriAdjustmentDays + 1,
                              ),
                            ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _SectionHeader('Today'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child:
                  controller.today == null
                      ? const Text('Prayer times unavailable.')
                      : Column(
                        children: [
                          ...controller.today!.orderedEntries.map(
                            (e) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(e.key.displayName),
                                  Text(formatTime(e.value)),
                                ],
                              ),
                            ),
                          ),
                          const Divider(),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Next reminder',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              Text(
                                controller.nextReminder == null
                                    ? 'None scheduled'
                                    : '${controller.nextReminder!.prayer.displayName} • ${formatDateTime(controller.nextReminder!.scheduledAt.toLocal())}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
            ),
          ),
          const SizedBox(height: 16),
          _SectionHeader('Actions'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.notifications_active_outlined),
                  title: const Text('Test notification'),
                  onTap: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    await controller.sendTestNotification();
                    messenger.showSnackBar(
                      const SnackBar(content: Text('Test notification sent.')),
                    );
                  },
                ),
                if (kDebugMode && controller.alarmKitAvailable) ...[
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.alarm_add_outlined),
                    title: const Text('Test AlarmKit in ~1 minute'),
                    subtitle: const Text(
                      'Debug only — schedules a prominent prayer alarm',
                    ),
                    onTap: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final ok =
                          await controller.scheduleAlarmKitDebugInOneMinute();
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(
                            ok
                                ? 'AlarmKit test scheduled (~1 min). Lock the phone or switch apps to verify.'
                                : 'Could not schedule AlarmKit test. Check alarm permission.',
                          ),
                        ),
                      );
                    },
                  ),
                ],
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.refresh),
                  title: const Text('Recalculate prayer times'),
                  onTap: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    await controller.recalculateAndReschedule();
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Prayer times recalculated and reminders rescheduled.',
                        ),
                      ),
                    );
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.phone_iphone),
                  title: const Text('Preview reminder screen'),
                  onTap: () async {
                    final prayer =
                        controller.nextPrayer?.key ?? SalahPrayer.dhuhr;
                    final result = await Navigator.of(
                      context,
                    ).push<IncomingSalahResult>(
                      MaterialPageRoute(
                        builder: (_) => IncomingSalahScreen(prayer: prayer),
                        fullscreenDialog: true,
                      ),
                    );
                    // Answer records the intent to pray; completion is
                    // confirmed later via the gentle home-screen prompt.
                    if (result == IncomingSalahResult.prayNow) {
                      await controller.markPrayerAnswered(prayer);
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SectionHeader('About'),
          Card(
            child: Column(
              children: [
                const _VersionTile(),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: const Text('Privacy Policy'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap:
                      () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const PrivacyPolicyScreen(),
                        ),
                      ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.bug_report_outlined),
                  title: const Text('Diagnostics (beta)'),
                  subtitle: const Text(
                    'Copyable report for beta feedback — no location or '
                    'prayer history included',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap:
                      () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const DiagnosticsScreen(),
                        ),
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.softGold.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.gold.withValues(alpha: 0.5)),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline, color: AppTheme.deepGreen),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    AppStrings.disclaimer,
                    style: TextStyle(color: AppTheme.deepGreen),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// Option picker in a draggable, scrollable bottom sheet so long lists
  /// (e.g. the thirteen calculation methods) are fully reachable on small
  /// screens.
  Future<void> _pickEnum<T>({
    required BuildContext context,
    required String title,
    required List<T> values,
    required T selected,
    required String Function(T) labelOf,
    required void Function(T) onSelected,
  }) async {
    final choice = await showModalBottomSheet<T>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder:
          (sheetContext) => SafeArea(
            child: DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.5,
              minChildSize: 0.3,
              maxChildSize: 0.9,
              builder:
                  (context, scrollController) => Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Expanded(
                        child: RadioGroup<T>(
                          groupValue: selected,
                          onChanged:
                              (value) => Navigator.of(sheetContext).pop(value),
                          child: ListView(
                            controller: scrollController,
                            children:
                                values
                                    .map(
                                      (v) => RadioListTile<T>(
                                        title: Text(labelOf(v)),
                                        value: v,
                                      ),
                                    )
                                    .toList(),
                          ),
                        ),
                      ),
                    ],
                  ),
            ),
          ),
    );
    if (choice != null) onSelected(choice);
  }
}

/// App name + live version from the platform package info,
/// e.g. "Version 1.0.0 (1)". Never hardcoded.
class _VersionTile extends StatefulWidget {
  const _VersionTile();

  @override
  State<_VersionTile> createState() => _VersionTileState();
}

class _VersionTileState extends State<_VersionTile> {
  String _version = '…';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform()
        .then((info) {
          if (mounted) {
            setState(
              () => _version = 'Version ${info.version} (${info.buildNumber})',
            );
          }
        })
        .catchError((Object _) {
          if (mounted) setState(() => _version = 'Version unavailable');
        });
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.mosque_outlined),
      title: const Text(AppStrings.appTitle),
      subtitle: Text(_version),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;

  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: AppTheme.emerald,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
