import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:vibration/vibration.dart';

import '../models/salah_prayer.dart';
import '../state/app_controller.dart';
import '../utils/app_strings.dart';
import '../utils/app_theme.dart';
import '../utils/system_ui.dart';
import '../widgets/prayer_call_scene.dart';

/// How the user left the incoming reminder screen. A null route result
/// (backing out without choosing) is a distinct third outcome — "dismissed"
/// — which the caller records separately and never treats as Decline.
enum IncomingSalahResult {
  /// "Answer" — the user is going to pray; the caller records the answered
  /// state and asks about completion later.
  prayNow,

  /// "Decline" — the configured snooze was scheduled and the declined state
  /// recorded before the screen popped.
  declined,
}

/// Incoming-call style reminder screen.
///
/// The visuals (vector arch scene, stars, rising aura, text, and the
/// Answer/Decline buttons) live in [PrayerCallScene], which the Android
/// App Guard block screen also uses — so both screens are always identical.
/// This widget adds the behavior: ringing vibration/haptics, system UI
/// handling, and what Answer/Decline do.
///
/// The screen always presents exactly two actions — Answer and Decline —
/// creating a real, conscious decision at every prayer. This dichotomy is
/// the core philosophy of the app and must not be softened with alternative
/// wording or optional modes. (Declining is still respectful in behavior:
/// it schedules the configured snooze, never a rejection.)
class IncomingSalahScreen extends StatefulWidget {
  final SalahPrayer prayer;

  /// Optional scheduled fire time (AlarmKit / notification payload).
  final DateTime? scheduledAt;

  /// Optional AlarmKit alarm identifier for diagnostics / cancel.
  final String? alarmId;

  const IncomingSalahScreen({
    super.key,
    required this.prayer,
    this.scheduledAt,
    this.alarmId,
  });

  @override
  State<IncomingSalahScreen> createState() => _IncomingSalahScreenState();
}

class _IncomingSalahScreenState extends State<IncomingSalahScreen>
    with WidgetsBindingObserver {
  Timer? _hapticTimer;

  /// Set once all alerting (vibration, haptics, ringing animation) has been
  /// stopped. Guards every async/timer callback so nothing continues after.
  bool _alertingStopped = false;

  /// Set once the user has chosen Answer or Decline, so a second tap (or a
  /// tap racing the pop) can never trigger a duplicate action.
  bool _actionChosen = false;

  bool _usingVibrator = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Hide system bars without immersiveSticky — that mode was leaving
    // Settings with unstable insets (scroll jump) after Preview returned.
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: const [],
    );
    // Lock to portrait so the call layout never rotates.
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    _startRinging();
  }

  /// Prefers a true repeating ring-like vibration pattern (Android); falls
  /// back to the subtle heavyImpact pulses where patterns are unsupported.
  Future<void> _startRinging() async {
    var patternSupported = false;
    if (!kIsWeb && Platform.isAndroid) {
      try {
        patternSupported = await Vibration.hasVibrator();
      } catch (_) {
        patternSupported = false;
      }
    }
    // The permission check above is async: alerting may have been stopped
    // (action taken, screen popped, app backgrounded) in the meantime.
    if (!mounted || _alertingStopped) return;
    if (patternSupported) {
      _usingVibrator = true;
      // Double buzz, pause, repeat — the cadence of a ringing phone.
      Vibration.vibrate(pattern: [0, 650, 350, 650, 1400], repeat: 0);
    } else {
      _startRingingHaptics();
    }
  }

  void _startRingingHaptics() {
    _buzz();
    _hapticTimer = Timer.periodic(
      const Duration(milliseconds: 2600),
      (_) => _buzz(),
    );
  }

  /// Two short pulses, like a gentle ring vibration. Subtle on purpose.
  Future<void> _buzz() async {
    if (_alertingStopped) return;
    HapticFeedback.heavyImpact();
    await Future.delayed(const Duration(milliseconds: 160));
    if (_alertingStopped) return;
    HapticFeedback.heavyImpact();
  }

  /// Stops ALL alerting immediately: repeating vibration, the haptic loop
  /// timer, and the ringing-specific animations (via [PrayerCallScene]'s
  /// `ringing` flag). Idempotent — safe to call any number of times, from
  /// any exit path (Answer, Decline, back-out, app lifecycle change,
  /// disposal). The ambient scene motion keeps playing — it's atmosphere,
  /// not a ringing signal — until the route actually pops.
  void _stopAlerting({bool rebuild = true}) {
    if (_alertingStopped) return;
    _alertingStopped = true;
    _hapticTimer?.cancel();
    _hapticTimer = null;
    if (_usingVibrator) {
      _usingVibrator = false;
      Vibration.cancel();
    }
    if (rebuild && mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // If the app leaves the foreground unexpectedly (call, task switch,
    // screen lock), the "incoming call" must fall silent like a real one.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _stopAlerting();
    }
  }

  @override
  void dispose() {
    // Covers every remaining exit: route popped, notification cancelled
    // externally while the route unwinds, widget tree teardown.
    _stopAlerting(rebuild: false);
    WidgetsBinding.instance.removeObserver(this);
    restoreAppSystemUi();
    super.dispose();
  }

  Future<void> _answer() async {
    if (_actionChosen) return;
    _actionChosen = true;
    _stopAlerting();
    // Restore chrome *before* popping so Settings never paints one frame
    // still missing status/nav insets (that was the scroll glitch).
    restoreAppSystemUi();
    HapticFeedback.selectionClick();
    // The caller records the answered state and shows the gentle completion
    // prompt later.
    Navigator.of(context).pop(IncomingSalahResult.prayNow);
  }

  /// Decline: dismisses the screen and schedules the configured snooze.
  Future<void> _decline() async {
    if (_actionChosen) return;
    _actionChosen = true;
    _stopAlerting();
    restoreAppSystemUi();
    final controller = context.read<AppController>();
    final messenger = ScaffoldMessenger.of(context);
    final minutes = controller.settings.snoozeMinutes;
    await controller.snooze(widget.prayer);
    if (!mounted) return;
    Navigator.of(context).pop(IncomingSalahResult.declined);
    messenger.showSnackBar(
      SnackBar(content: Text(AppStrings.snoozeConfirmation(minutes))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.forPrayer(widget.prayer);
    return Scaffold(
      backgroundColor: theme.gradientBottom,
      body: PrayerCallScene(
        prayerLabel: widget.prayer.displayName,
        supportingLine: AppStrings.incomingSupportingLine(widget.prayer),
        palette: theme,
        ringing: !_alertingStopped,
        onAnswer: _answer,
        onDecline: _decline,
      ),
    );
  }
}
