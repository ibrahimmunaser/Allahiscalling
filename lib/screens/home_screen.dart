import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hijri/hijri_calendar.dart';
import 'package:provider/provider.dart';

import '../models/salah_prayer.dart';
import '../services/location_service.dart';
import '../state/app_controller.dart';
import '../utils/app_strings.dart';
import '../utils/app_theme.dart';
import '../utils/formatting.dart';
import '../widgets/location_feedback.dart';
import '../widgets/prayer_times_list.dart';
import 'debug_prayer_screen.dart';
import 'manual_location_screen.dart';
import 'qibla_screen.dart';
import 'quran_hub_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _guidanceFlowStarted = false;

  /// One-time onboarding guidance shown after initialization: first the
  /// Android full-screen intent explanation (only on Android versions that
  /// actually require the special permission), then (on aggressive OEMs)
  /// the battery reliability tips.
  Future<void> _runOnboardingGuidance(AppController controller) async {
    final needsFsiGuidance = await controller.needsFullScreenGuidance();
    if (needsFsiGuidance && mounted) {
      final proceed = await showDialog<bool>(
        context: context,
        builder:
            (dialogContext) => AlertDialog(
              title: const Text(AppStrings.fullScreenGuidanceTitle),
              content: const Text(AppStrings.fullScreenGuidanceBody),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Not now'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Continue'),
                ),
              ],
            ),
      );
      if (proceed == true) {
        await controller.acceptFullScreenGuidance();
      } else {
        await controller.dismissFullScreenGuidance();
      }
    }

    final manufacturer = await controller.pendingBatteryGuidance();
    if (manufacturer != null && mounted) {
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder:
            (sheetContext) => SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(
                          Icons.battery_alert_outlined,
                          color: AppTheme.emerald,
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            AppStrings.batteryGuidanceTitle,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(AppStrings.batteryGuidanceBody),
                    const SizedBox(height: 8),
                    Text(
                      '$manufacturer devices may silence scheduled reminders to '
                      'save battery. Look for "Battery" or "Background activity" '
                      'in this app\'s system settings and remove restrictions.',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(sheetContext).pop(),
                            child: const Text('Got it'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: () {
                              Navigator.of(sheetContext).pop();
                              LocationService().openAppSettings();
                            },
                            child: const Text('Open settings'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
      );
      await controller.markBatteryGuidanceShown();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();

    if (controller.initialized && !_guidanceFlowStarted) {
      _guidanceFlowStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _runOnboardingGuidance(controller);
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          AppStrings.appTitle,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed:
                () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
          ),
        ],
      ),
      bottomNavigationBar: const _QuranQiblaBottomBar(),
      body:
          !controller.initialized
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                onRefresh: controller.recalculateAndReschedule,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _HijriDateLine(controller: controller),
                    const SizedBox(height: 10),
                    _NextPrayerCard(controller: controller),
                    const SizedBox(height: 16),
                    if (controller.pendingCompletionPrayer != null) ...[
                      _CompletionCard(
                        controller: controller,
                        prayer: controller.pendingCompletionPrayer!,
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (controller.today != null) ...[
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Today',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.deepGreen,
                                ),
                              ),
                              const SizedBox(height: 8),
                              PrayerTimesList(
                                day: controller.today!,
                                highlighted: controller.nextPrayer?.key,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ] else
                      _LocationNeededCard(controller: controller),
                    const SizedBox(height: 16),
                    Center(
                      child: Text(
                        AppStrings.disclaimer,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: TextButton.icon(
                        onPressed:
                            () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const DebugPrayerScreen(),
                              ),
                            ),
                        icon: const Icon(Icons.bug_report_outlined, size: 16),
                        label: const Text('Debug info'),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.grey.shade500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
    );
  }
}

/// Hijri (Islamic) date alongside the Gregorian date, computed in the
/// user's prayer timezone so the day flips at the right local midnight.
/// The user's Hijri adjustment (±2 days, for local moon sighting) applies
/// only to this display — never to salah calculations.
class _HijriDateLine extends StatelessWidget {
  final AppController controller;

  const _HijriDateLine({required this.controller});

  @override
  Widget build(BuildContext context) {
    final now = controller.nowInUserZone();
    final hijri = HijriCalendar.fromDate(
      now.add(Duration(days: controller.settings.hijriAdjustmentDays)),
    );
    return Center(
      child: Text(
        '${hijri.hDay} ${hijri.longMonthName} ${hijri.hYear} AH'
        '  •  ${formatDate(now)}',
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppTheme.emerald,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

class _NextPrayerCard extends StatelessWidget {
  final AppController controller;

  const _NextPrayerCard({required this.controller});

  @override
  Widget build(BuildContext context) {
    final next = controller.nextPrayer;

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.deepGreen, AppTheme.emerald],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child:
          next == null
              ? const Text(
                'Prayer times unavailable.\nPlease set your location.',
                style: TextStyle(color: AppTheme.ivory, fontSize: 16),
                textAlign: TextAlign.center,
              )
              : Column(
                children: [
                  const Text(
                    'Next Prayer',
                    style: TextStyle(
                      color: AppTheme.softGold,
                      fontSize: 14,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    next.key.displayName,
                    style: const TextStyle(
                      color: AppTheme.ivory,
                      fontSize: 40,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    formatTime(next.value),
                    style: const TextStyle(
                      color: AppTheme.ivory,
                      fontSize: 22,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.gold.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppTheme.gold),
                    ),
                    child: _CountdownText(
                      controller: controller,
                      target: next.value,
                    ),
                  ),
                  if (controller.settings.locationLabel != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      controller.settings.locationLabel!,
                      style: TextStyle(
                        color: AppTheme.ivory.withValues(alpha: 0.7),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
    );
  }
}

/// Self-ticking countdown. Owns its own one-second timer so the rest of the
/// screen (and the astronomical calculations behind it) are not rebuilt
/// every second; the controller's memoized next-prayer stays untouched
/// until this countdown actually reaches zero.
class _CountdownText extends StatefulWidget {
  final AppController controller;
  final DateTime target;

  const _CountdownText({required this.controller, required this.target});

  @override
  State<_CountdownText> createState() => _CountdownTextState();
}

class _CountdownTextState extends State<_CountdownText> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      // Countdown finished: the next prayer changed. Nudge the controller
      // so the whole card (name, time, highlight) refreshes once.
      if (!widget.target.isAfter(widget.controller.nowInUserZone())) {
        widget.controller.refreshNextPrayer();
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.target.difference(
      widget.controller.nowInUserZone(),
    );
    return Text(
      'in ${formatCountdown(remaining)}',
      style: const TextStyle(
        color: AppTheme.softGold,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// Gentle, non-intrusive completion check-in: shown on the home screen only
/// after the user answered a reminder, a respectful delay has passed, and
/// the prayer window is still open. Never a second full-screen interruption.
class _CompletionCard extends StatelessWidget {
  final AppController controller;
  final SalahPrayer prayer;

  const _CompletionCard({required this.controller, required this.prayer});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            const Icon(Icons.check_circle_outline, color: AppTheme.emerald),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                AppStrings.didYouComplete(prayer.displayName),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton(
              onPressed: () => controller.markPrayerCompleted(prayer),
              child: const Text('Mark as Prayed'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LocationNeededCard extends StatelessWidget {
  final AppController controller;

  const _LocationNeededCard({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const Icon(
              Icons.location_on_outlined,
              size: 40,
              color: AppTheme.emerald,
            ),
            const SizedBox(height: 12),
            const Text(
              AppStrings.useLocationPrompt,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              'Prayer times are calculated from your coordinates, so the '
              'closer the location, the more accurate the times.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () async {
                final status = await controller.useCurrentLocation();
                if (!context.mounted) return;
                showLocationStatusFeedback(context, status);
              },
              icon: const Icon(Icons.my_location),
              label: const Text('Use current location'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const ManualLocationScreen(),
                    ),
                  ),
              icon: const Icon(Icons.search, size: 18),
              label: const Text(AppStrings.searchYourCity),
            ),
            TextButton(
              onPressed:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const ManualLocationScreen(initialTab: 1),
                    ),
                  ),
              child: const Text(AppStrings.enterCoordinatesManually),
            ),
          ],
        ),
      ),
    );
  }
}

/// Split bottom bar: half Quran, half Qibla.
class _QuranQiblaBottomBar extends StatelessWidget {
  const _QuranQiblaBottomBar();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.deepGreen,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              Expanded(
                child: _BottomBarHalf(
                  icon: Icons.menu_book_outlined,
                  label: AppStrings.quranTitle,
                  onTap:
                      () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const QuranHubScreen(),
                        ),
                      ),
                ),
              ),
              Container(
                width: 1,
                height: 36,
                color: AppTheme.ivory.withValues(alpha: 0.25),
              ),
              Expanded(
                child: _BottomBarHalf(
                  icon: Icons.explore_outlined,
                  label: AppStrings.qiblaTitle,
                  onTap:
                      () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const QiblaScreen()),
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomBarHalf extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _BottomBarHalf({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: AppTheme.ivory, size: 26),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              color: AppTheme.ivory,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
