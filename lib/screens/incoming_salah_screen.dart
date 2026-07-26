import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:vibration/vibration.dart';

import '../models/salah_prayer.dart';
import '../state/app_controller.dart';
import '../utils/app_strings.dart';
import '../utils/app_theme.dart';

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
/// Designed to feel like an important incoming call: expanding ripple rings,
/// a glowing pulsing Answer button, gentle ringing haptics.
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
    with TickerProviderStateMixin, WidgetsBindingObserver {
  /// Drives the expanding "ringing" ripple rings.
  late final AnimationController _rippleController;

  /// Drives the Answer button glow/scale pulse.
  late final AnimationController _pulseController;

  /// Drives the periodic ringing wiggle of the Answer button.
  late final AnimationController _shakeController;

  Timer? _hapticTimer;

  /// Set once all alerting (vibration, haptics, animation) has been stopped.
  /// Guards every async/timer callback so nothing continues afterwards.
  bool _alertingStopped = false;

  /// Set once the user has chosen Answer or Decline, so a second tap (or a
  /// tap racing the pop) can never trigger a duplicate action.
  bool _actionChosen = false;

  bool _usingVibrator = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..repeat(reverse: true);
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat();

    // Immersive full-screen, like a real incoming call.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
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
  /// timer, and every animation. Idempotent — safe to call any number of
  /// times, from any exit path (Answer, Decline, back-out, app lifecycle
  /// change, disposal).
  void _stopAlerting() {
    if (_alertingStopped) return;
    _alertingStopped = true;
    _hapticTimer?.cancel();
    _hapticTimer = null;
    if (_usingVibrator) {
      _usingVibrator = false;
      Vibration.cancel();
    }
    // Stop (don't dispose — dispose() owns that) so ripple/pulse/wiggle
    // freeze instantly rather than animating on after the choice was made.
    _rippleController.stop();
    _pulseController.stop();
    _shakeController.stop();
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
    _stopAlerting();
    WidgetsBinding.instance.removeObserver(this);
    _rippleController.dispose();
    _pulseController.dispose();
    _shakeController.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // Restore all orientations when leaving the call screen.
    SystemChrome.setPreferredOrientations([]);
    super.dispose();
  }

  Future<void> _answer() async {
    if (_actionChosen) return;
    _actionChosen = true;
    _stopAlerting();
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
    return Scaffold(
      backgroundColor: AppTheme.nightBlue,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Deep vertical gradient, like a call screen at night.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF061511),
                  AppTheme.nightBlue,
                  AppTheme.deepGreen,
                ],
                stops: [0.0, 0.45, 1.0],
              ),
            ),
          ),
          // Soft radial glow behind the avatar.
          Align(
            alignment: const Alignment(0, -0.38),
            child: Container(
              width: 380,
              height: 380,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    AppTheme.gold.withValues(alpha: 0.10),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                const Spacer(flex: 2),
                // Ringing avatar with expanding ripple rings.
                SizedBox(
                  width: 300,
                  height: 300,
                  child: AnimatedBuilder(
                    animation: _rippleController,
                    builder:
                        (context, child) => CustomPaint(
                          painter: _RipplePainter(_rippleController.value),
                          child: child,
                        ),
                    child: Center(
                      child: Container(
                        width: 132,
                        height: 132,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [AppTheme.emerald, AppTheme.deepGreen],
                          ),
                          border: Border.all(color: AppTheme.gold, width: 2),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.45),
                              blurRadius: 30,
                              offset: const Offset(0, 12),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.mosque_outlined,
                          size: 60,
                          color: AppTheme.softGold,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                // 1. Permanent title — honorable, personal, welcoming.
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    AppStrings.incomingCallTitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppTheme.ivory,
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      height: 1.25,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                // 2. Prayer name (call-style emphasis).
                Text(
                  widget.prayer.displayName.toUpperCase(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppTheme.softGold,
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 3.5,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 10),
                // 3. Status — prayer has entered.
                Text(
                  AppStrings.prayerEnteredBody(widget.prayer.displayName),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppTheme.ivory.withValues(alpha: 0.88),
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 18),
                // 4. One short supporting line (prayer-specific only —
                // never shown together with the generic fallback).
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Text(
                    AppStrings.incomingSupportingLine(widget.prayer),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppTheme.softGold.withValues(alpha: 0.90),
                      fontSize: 17,
                      fontWeight: FontWeight.w400,
                      height: 1.4,
                      letterSpacing: 0.15,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
                const Spacer(flex: 3),
                // Incoming-call action row: red decline-style "later" vs radiant "answer".
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 44),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _CallAction(
                        label: AppStrings.declineLabel,
                        labelColor: Colors.red.shade300,
                        semanticLabel: 'Decline prayer reminder',
                        semanticHint: 'Dismisses and reminds you again later',
                        onTap: _decline,
                        button: _DeclineButton(onTap: _decline),
                      ),
                      _CallAction(
                        label: AppStrings.answer,
                        labelColor: AppTheme.softGold,
                        semanticLabel: 'Answer prayer reminder',
                        semanticHint: 'You are going to pray now',
                        onTap: _answer,
                        button: _AnswerButton(
                          pulse: _pulseController,
                          shake: _shakeController,
                          onTap: _answer,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 56),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A circular call action with its label underneath, bottom-aligned so the
/// two differently sized buttons share a baseline.
///
/// Exposed to assistive technology as a single button (icon and visible
/// label merged into one node) so VoiceOver/TalkBack reads e.g. "Answer
/// prayer reminder, button" once, never two unrelated nodes.
class _CallAction extends StatelessWidget {
  final String label;
  final Color labelColor;
  final String semanticLabel;
  final String semanticHint;
  final VoidCallback onTap;
  final Widget button;

  const _CallAction({
    required this.label,
    required this.labelColor,
    required this.semanticLabel,
    required this.semanticHint,
    required this.onTap,
    required this.button,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      hint: semanticHint,
      onTap: onTap,
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            button,
            const SizedBox(height: 14),
            Text(
              label,
              style: TextStyle(
                color: labelColor,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Red Decline button — visually matches the "end/decline call" button on
/// every smartphone, making the dichotomy between the two actions
/// immediately legible. The behavior is still a respectful snooze.
class _DeclineButton extends StatelessWidget {
  final VoidCallback onTap;

  const _DeclineButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFD32F2F);
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: red.withValues(alpha: 0.38),
            blurRadius: 18,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Material(
        color: red,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: const SizedBox(
            width: 78,
            height: 78,
            child: Icon(Icons.call_end, size: 34, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// Radiant, pulsing, gently wiggling primary action — the one the eye and
/// thumb are drawn to, like answering a call.
class _AnswerButton extends StatelessWidget {
  final Animation<double> pulse;
  final Animation<double> shake;
  final VoidCallback onTap;

  const _AnswerButton({
    required this.pulse,
    required this.shake,
    required this.onTap,
  });

  /// Short wiggle at the start of each cycle, then rest — like a ringing
  /// phone, without being frantic.
  double _angle(double t) {
    if (t >= 0.22) return 0;
    return math.sin(t / 0.22 * math.pi * 3) * 0.07;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([pulse, shake]),
      builder: (context, child) {
        final p = Curves.easeInOut.transform(pulse.value);
        return Transform.rotate(
          angle: _angle(shake.value),
          child: Transform.scale(
            scale: 1.0 + 0.05 * p,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.gold.withValues(alpha: 0.30 + 0.25 * p),
                    blurRadius: 22 + 16 * p,
                    spreadRadius: 2 + 5 * p,
                  ),
                ],
              ),
              child: child,
            ),
          ),
        );
      },
      child: Material(
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          width: 90,
          height: 90,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFE3BE63), AppTheme.gold],
            ),
          ),
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: const Icon(Icons.call, size: 36, color: AppTheme.nightBlue),
          ),
        ),
      ),
    );
  }
}

/// Expanding, fading concentric rings radiating from the avatar — the visual
/// language of a ringing call.
class _RipplePainter extends CustomPainter {
  final double progress;

  _RipplePainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.width / 2;
    for (var i = 0; i < 3; i++) {
      final p = (progress + i / 3) % 1.0;
      final radius = lerpDouble(70, maxRadius, Curves.easeOut.transform(p))!;
      final opacity = (1 - p) * 0.32;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = AppTheme.gold.withValues(alpha: opacity),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RipplePainter oldDelegate) =>
      oldDelegate.progress != progress;
}
