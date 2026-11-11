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
import '../utils/incoming_call_background.dart';
import '../utils/system_ui.dart';

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
/// The upper portion is a prayer-specific illustrated scene (one hand-built
/// image per salah) carrying the title, prayer name, and supporting line.
/// It's brought to life with a slow Ken Burns drift, a breathing radiant
/// glow, and a soft light sweep across the art. Below it, a real, animated,
/// fully accessible Answer/Decline action row — expanding ripple rings,
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
  /// Drives the Answer button glow/scale pulse.
  late final AnimationController _pulseController;

  /// Drives the periodic ringing wiggle of the Answer button.
  late final AnimationController _shakeController;

  /// Drives the expanding ripple rings behind the Answer button.
  late final AnimationController _rippleController;

  /// Slow continuous zoom on the hero artwork — subtle "alive" motion.
  late final AnimationController _kenBurnsController;

  /// Breathing radiant glow layered over the artwork.
  late final AnimationController _auraController;

  /// Soft diagonal light sweep drifting across the artwork/text.
  late final AnimationController _shimmerController;

  /// One-shot entrance: fades + scales the whole screen in on arrival.
  late final AnimationController _entranceController;

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
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..repeat(reverse: true);
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat();
    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
    _kenBurnsController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 9000),
    )..repeat(reverse: true);
    _auraController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4200),
    )..repeat();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 750),
    )..forward();

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
  /// timer, and the ringing-specific animations. Idempotent — safe to call
  /// any number of times, from any exit path (Answer, Decline, back-out, app
  /// lifecycle change, disposal).
  void _stopAlerting() {
    if (_alertingStopped) return;
    _alertingStopped = true;
    _hapticTimer?.cancel();
    _hapticTimer = null;
    if (_usingVibrator) {
      _usingVibrator = false;
      Vibration.cancel();
    }
    // Stop (don't dispose — dispose() owns that) so the pulse/wiggle/ripple
    // freeze instantly rather than animating on after the choice was made.
    // The ambient scene motion (Ken Burns/aura/shimmer) keeps playing —
    // it's atmosphere, not a ringing signal — until the route actually pops.
    _pulseController.stop();
    _shakeController.stop();
    _rippleController.stop();
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
    _pulseController.dispose();
    _shakeController.dispose();
    _rippleController.dispose();
    _kenBurnsController.dispose();
    _auraController.dispose();
    _shimmerController.dispose();
    _entranceController.dispose();
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
    final asset = IncomingCallBackground.assetFor(widget.prayer);
    final panelTop = theme.gradientBottom;
    final panelBottom = Color.lerp(theme.gradientBottom, AppTheme.gold, 0.55)!;

    return Scaffold(
      backgroundColor: panelTop,
      body: FadeTransition(
        opacity: CurvedAnimation(parent: _entranceController, curve: Curves.easeOut),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.97, end: 1.0).animate(
            CurvedAnimation(parent: _entranceController, curve: Curves.easeOutCubic),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // The hero art is cropped to just above the point where the
              // source illustration's own (non-interactive) button row
              // begins, so only the arch/title/supporting-line portion
              // shows — real, accessible buttons live in the panel below.
              const maxArtFraction = 0.70;
              const minPanelHeight = 210.0;
              final renderedImageHeight =
                  constraints.maxWidth / IncomingCallBackground.nativeAspect;
              var artHeight = renderedImageHeight * maxArtFraction;
              if (constraints.maxHeight - artHeight < minPanelHeight) {
                artHeight = (constraints.maxHeight - minPanelHeight).clamp(
                  0.0,
                  renderedImageHeight,
                );
              }
              return Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    height: artHeight,
                    child: _HeroArt(
                      asset: asset,
                      renderedImageHeight: renderedImageHeight,
                      fadeToColor: panelTop,
                      kenBurns: _kenBurnsController,
                      aura: _auraController,
                      shimmer: _shimmerController,
                      accent: theme.accent,
                    ),
                  ),
                  Expanded(
                    child: _ActionPanel(
                      theme: theme,
                      gradientTop: panelTop,
                      gradientBottom: panelBottom,
                      pulse: _pulseController,
                      shake: _shakeController,
                      ripple: _rippleController,
                      onAnswer: _answer,
                      onDecline: _decline,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The illustrated prayer scene, animated with a slow Ken Burns drift, a
/// breathing radiant glow, and a soft light sweep — then faded seamlessly
/// into the action panel's background color at the bottom.
class _HeroArt extends StatelessWidget {
  final String asset;
  final double renderedImageHeight;
  final Color fadeToColor;
  final Animation<double> kenBurns;
  final Animation<double> aura;
  final Animation<double> shimmer;
  final Color accent;

  const _HeroArt({
    required this.asset,
    required this.renderedImageHeight,
    required this.fadeToColor,
    required this.kenBurns,
    required this.aura,
    required this.shimmer,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: AnimatedBuilder(
              animation: kenBurns,
              builder: (context, child) {
                final t = Curves.easeInOut.transform(kenBurns.value);
                return Transform.scale(
                  scale: 1.0 + 0.045 * t,
                  alignment: Alignment.topCenter,
                  child: child,
                );
              },
              child: SizedBox(
                width: double.infinity,
                height: renderedImageHeight,
                child: Image.asset(
                  asset,
                  fit: BoxFit.fitWidth,
                  alignment: Alignment.topCenter,
                ),
              ),
            ),
          ),
          // Soft diagonal light sweep drifting across the art and its
          // baked-in text, like light moving across glass.
          IgnorePointer(
            child: AnimatedBuilder(
              animation: shimmer,
              builder: (context, _) {
                final t = shimmer.value;
                return DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment(-1.6 + 3.2 * t, -1.0),
                      end: Alignment(-0.6 + 3.2 * t, 1.0),
                      colors: [
                        Colors.transparent,
                        Colors.white.withValues(alpha: 0.14),
                        Colors.transparent,
                      ],
                      stops: const [0.35, 0.5, 0.65],
                    ),
                  ),
                );
              },
            ),
          ),
          // Breathing radiant glow — "radiating light" over the arch.
          IgnorePointer(
            child: Align(
              alignment: const Alignment(0, 0.3),
              child: AnimatedBuilder(
                animation: aura,
                builder: (context, _) {
                  final t = Curves.easeInOut.transform(aura.value);
                  return Container(
                    width: 240 + 50 * t,
                    height: 240 + 50 * t,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          Colors.white.withValues(alpha: 0.16 * t),
                          accent.withValues(alpha: 0.12 * t),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          // Seamless fade into the action panel below.
          IgnorePointer(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                height: 150,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, fadeToColor],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The bottom action row: Decline / Answer, over a warm gradient panel that
/// continues the art's atmosphere.
class _ActionPanel extends StatelessWidget {
  final PrayerPalette theme;
  final Color gradientTop;
  final Color gradientBottom;
  final Animation<double> pulse;
  final Animation<double> shake;
  final Animation<double> ripple;
  final VoidCallback onAnswer;
  final VoidCallback onDecline;

  const _ActionPanel({
    required this.theme,
    required this.gradientTop,
    required this.gradientBottom,
    required this.pulse,
    required this.shake,
    required this.ripple,
    required this.onAnswer,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [gradientTop, gradientBottom],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(44, 10, 44, 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _CallAction(
                label: AppStrings.declineLabel,
                labelColor: Colors.red.shade100,
                semanticLabel: 'Decline prayer reminder',
                semanticHint: 'Dismisses and reminds you again later',
                onTap: onDecline,
                button: _DeclineButton(onTap: onDecline),
              ),
              _CallAction(
                label: AppStrings.answer,
                labelColor: AppTheme.ivory,
                semanticLabel: 'Answer prayer reminder',
                semanticHint: 'You are going to pray now',
                onTap: onAnswer,
                button: _AnswerButtonWithRipple(
                  pulse: pulse,
                  shake: shake,
                  ripple: ripple,
                  onTap: onAnswer,
                  theme: theme,
                ),
              ),
            ],
          ),
        ),
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

/// Wraps [_AnswerButton] with small expanding ripple rings, like the visual
/// language of a ringing call concentrated around the one action that
/// matters.
class _AnswerButtonWithRipple extends StatelessWidget {
  final Animation<double> pulse;
  final Animation<double> shake;
  final Animation<double> ripple;
  final VoidCallback onTap;
  final PrayerPalette theme;

  const _AnswerButtonWithRipple({
    required this.pulse,
    required this.shake,
    required this.ripple,
    required this.onTap,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      height: 150,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: ripple,
            builder:
                (context, _) => CustomPaint(
                  painter: _RipplePainter(
                    ripple.value,
                    theme.accent,
                    baseRadius: 42,
                    maxRadius: 74,
                  ),
                ),
          ),
          _AnswerButton(pulse: pulse, shake: shake, onTap: onTap, theme: theme),
        ],
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
  final PrayerPalette theme;

  const _AnswerButton({
    required this.pulse,
    required this.shake,
    required this.onTap,
    required this.theme,
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
                    color: theme.accent.withValues(alpha: 0.30 + 0.25 * p),
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
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [theme.softAccent, theme.accent],
            ),
          ),
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: Icon(Icons.call, size: 36, color: theme.onAccent),
          ),
        ),
      ),
    );
  }
}

/// Expanding, fading concentric rings — the visual language of a ringing
/// call. [baseRadius]/[maxRadius] let the same painter serve both a large
/// avatar (legacy) and a tight ring hugging a single button.
class _RipplePainter extends CustomPainter {
  final double progress;
  final Color accent;
  final double baseRadius;
  final double maxRadius;

  _RipplePainter(
    this.progress,
    this.accent, {
    this.baseRadius = 70,
    this.maxRadius = 150,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    for (var i = 0; i < 3; i++) {
      final p = (progress + i / 3) % 1.0;
      final radius =
          lerpDouble(baseRadius, maxRadius, Curves.easeOut.transform(p))!;
      final opacity = (1 - p) * 0.32;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = accent.withValues(alpha: opacity),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RipplePainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.accent != accent ||
      oldDelegate.baseRadius != baseRadius ||
      oldDelegate.maxRadius != maxRadius;
}
