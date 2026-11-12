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
/// The upper portion is a vector-drawn Islamic arch scene — gradient sky,
/// a glowing arch outline, and crisp real text carrying the title, prayer
/// name, and supporting line. Nothing here is a raster image, so it stays
/// sharp at any screen density. It's brought to life with a slow Ken Burns
/// drift, a breathing radiant glow, and a soft light sweep across the
/// scene. Below it, a real, animated, fully accessible Answer/Decline
/// action row — expanding ripple rings, a glowing pulsing Answer button,
/// gentle ringing haptics.
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

  /// Radiating light bursting from the bottom edge, behind the buttons.
  late final AnimationController _sunburstController;

  /// A magical aura that rises from the bottom edge of the whole screen
  /// toward the middle, fading in and out as it travels — layered over
  /// everything else.
  late final AnimationController _risingAuraController;

  /// Independent per-star twinkle phase for the starfield behind the arch.
  late final AnimationController _twinkleController;

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
    _sunburstController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3400),
    )..repeat(reverse: true);
    _risingAuraController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4200),
    )..repeat();
    _twinkleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 7000),
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
    _sunburstController.dispose();
    _risingAuraController.dispose();
    _twinkleController.dispose();
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
    final panelTop = theme.gradientBottom;
    // Blend toward THIS prayer's own accent, not a universal gold — gold
    // flatters Asr/Maghrib's warm scenes but turns Fajr/Isha's cool blues
    // into a muddy grey. Each palette's accent was already tuned to sit
    // well against its own gradientBottom, so the glow stays cohesive
    // (warm sun for Asr/Dhuhr/Maghrib, cool moonlight for Fajr/Isha).
    final panelBottom = Color.lerp(theme.gradientBottom, theme.accent, 0.5)!;

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
              // The vector arch scene takes most of the screen; real,
              // accessible Answer/Decline buttons live in the panel below.
              const artFraction = 0.64;
              const minPanelHeight = 230.0;
              var artHeight = constraints.maxHeight * artFraction;
              if (constraints.maxHeight - artHeight < minPanelHeight) {
                artHeight = (constraints.maxHeight - minPanelHeight).clamp(
                  0.0,
                  constraints.maxHeight,
                );
              }
              return Stack(
                children: [
                  Column(
                    children: [
                      SizedBox(
                        width: double.infinity,
                        height: artHeight,
                        child: _HeroArt(
                          prayer: widget.prayer,
                          palette: theme,
                          fadeToColor: panelTop,
                          kenBurns: _kenBurnsController,
                          aura: _auraController,
                          shimmer: _shimmerController,
                          twinkle: _twinkleController,
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
                          sunburst: _sunburstController,
                          onAnswer: _answer,
                          onDecline: _decline,
                        ),
                      ),
                    ],
                  ),
                  // A magical aura that rises from the very bottom of the
                  // screen toward the middle, fading in and out as it
                  // travels — floated over the whole scene, not just one
                  // section of it.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: _RisingAuraGlow(
                        controller: _risingAuraController,
                        color: theme.accent,
                      ),
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

/// The prayer scene — a per-prayer gradient sky, a vector-drawn glowing
/// Islamic arch, and crisp real text (eyebrow label, prayer name, headline,
/// supporting line). Nothing here is a raster image: every line and letter
/// is drawn at the device's own resolution, so it's sharp on every screen,
/// unlike a fixed-size bitmap stretched to fit. Animated with a slow Ken
/// Burns drift, a breathing radiant glow, and a soft light sweep — then
/// faded seamlessly into the action panel's background color at the bottom.
class _HeroArt extends StatelessWidget {
  final SalahPrayer prayer;
  final PrayerPalette palette;
  final Color fadeToColor;
  final Animation<double> kenBurns;
  final Animation<double> aura;
  final Animation<double> shimmer;
  final Animation<double> twinkle;

  const _HeroArt({
    required this.prayer,
    required this.palette,
    required this.fadeToColor,
    required this.kenBurns,
    required this.aura,
    required this.shimmer,
    required this.twinkle,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Per-prayer sky, flowing straight into the action panel's own
          // gradient below it — one continuous backdrop, not a flat image.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  palette.gradientTop,
                  palette.gradientMid,
                  fadeToColor,
                ],
                stops: const [0.0, 0.55, 1.0],
              ),
            ),
          ),
          AnimatedBuilder(
            animation: kenBurns,
            builder: (context, child) {
              final t = Curves.easeInOut.transform(kenBurns.value);
              return Transform.scale(
                scale: 1.0 + 0.035 * t,
                alignment: const Alignment(0, -0.2),
                child: child,
              );
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                // A quiet scatter of twinkling stars in the upper sky —
                // the first hint that this scene is alive, not flat.
                Positioned.fill(
                  child: CustomPaint(
                    painter: _StarFieldPainter(twinkle: twinkle),
                  ),
                ),
                // Breathing radiant glow behind the arch.
                IgnorePointer(
                  child: Align(
                    alignment: const Alignment(0, -0.15),
                    child: AnimatedBuilder(
                      animation: aura,
                      builder: (context, _) {
                        final t = Curves.easeInOut.transform(aura.value);
                        return Container(
                          width: 280 + 90 * t,
                          height: 280 + 90 * t,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                Colors.white.withValues(alpha: 0.18 * t),
                                palette.accent.withValues(alpha: 0.16 * t),
                                palette.softAccent.withValues(alpha: 0.08 * t),
                                Colors.transparent,
                              ],
                              stops: const [0.0, 0.35, 0.65, 1.0],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                // Vector Islamic arch — a glowing outline, crisp at any
                // resolution, in place of a baked-in raster illustration.
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: Listenable.merge([kenBurns, aura]),
                    builder: (context, _) {
                      return CustomPaint(
                        painter: _ArchPainter(
                          rim: AppTheme.softGold,
                          glow: AppTheme.gold,
                          rayRotation: kenBurns.value * math.pi / 6,
                          rayPulse: Curves.easeInOut.transform(aura.value),
                        ),
                      );
                    },
                  ),
                ),
                // Crisp, real text — never baked into an image.
                Positioned.fill(child: _HeroText(prayer: prayer)),
              ],
            ),
          ),
          // Soft diagonal light sweep drifting across the arch and text,
          // like light moving across glass.
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

/// A glowing Islamic pointed-arch outline — a bright, crisp rim over a
/// soft blurred glow, like neon against the night sky. Drawn with
/// [Canvas.drawPath] rather than decoded from a bitmap, so it is exactly as
/// sharp on a small phone as on a tablet.
class _ArchPainter extends CustomPainter {
  final Color rim;
  final Color glow;
  final double rayRotation;
  final double rayPulse;

  const _ArchPainter({
    required this.rim,
    required this.glow,
    required this.rayRotation,
    required this.rayPulse,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final outline = _buildPath(size, 0);
    final echo = _buildPath(size, size.width * 0.045);

    _drawHaloRays(canvas, size);

    // A faint inset "echo" of the arch just inside the main outline — the
    // double-line detailing of real Islamic doorway arches — drawn first
    // so the bright main outline sits on top of it.
    canvas.drawPath(
      echo,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..strokeCap = StrokeCap.round
        ..color = rim.withValues(alpha: 0.28),
    );

    final outerGlow =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 18
          ..strokeCap = StrokeCap.round
          ..color = glow.withValues(alpha: 0.32)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22);
    canvas.drawPath(outline, outerGlow);

    final innerGlow =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7
          ..strokeCap = StrokeCap.round
          ..color = glow.withValues(alpha: 0.58)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawPath(outline, innerGlow);

    final rimPaint =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..strokeCap = StrokeCap.round
          ..color = rim.withValues(alpha: 0.95);
    canvas.drawPath(outline, rimPaint);

    // A small bright finial where the two sides meet at the point — a
    // tiny focal spark, like the real thing is capped in gold.
    final apex = Offset(size.width / 2, size.height * 0.04);
    canvas.drawCircle(
      apex,
      5,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.9)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
  }

  /// Slow-rotating, slowly-breathing rays fanning out behind the arch's
  /// point — a quiet halo/mandorla, the kind of small extra detail that
  /// keeps the scene from reading as a flat, static outline.
  void _drawHaloRays(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.30);
    const rayCount = 20;
    final paint =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..strokeCap = StrokeCap.round
          ..color = Colors.white.withValues(alpha: 0.05 + 0.05 * rayPulse)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0);
    // Kept well inside the arch's silhouette so it reads as a soft glow
    // behind the point, never as lines poking past the outline.
    final innerR = size.width * 0.07;
    final outerR = size.width * (0.14 + 0.03 * rayPulse);
    for (var i = 0; i < rayCount; i++) {
      final angle = rayRotation + (i / rayCount) * 2 * math.pi;
      final dir = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(center + dir * innerR, center + dir * outerR, paint);
    }
  }

  /// An onion-dome ("ogee") silhouette: near-vertical walls rise from
  /// inset feet, bulge outward past the feet to their widest point around
  /// the springline, then sweep sharply back in to a crisp point at the
  /// top — the flame-like profile of a real mosque doorway, not a flat
  /// triangle. [inset] shrinks the whole shape inward by a fixed amount,
  /// used to draw the fainter echo line just inside the main outline.
  Path _buildPath(Size size, double inset) {
    final w = size.width;
    final h = size.height;
    final baseY = h * 0.985 - inset * 0.3;
    final apexY = h * 0.04 + inset * 1.6;
    final footInset = w * 0.07 + inset;
    final cx = w / 2;
    final halfSpan = cx - footInset;
    final bulgeSpan = halfSpan * 1.12;
    final bulgeY = h * 0.40 + inset * 0.6;

    final leftFootX = cx - halfSpan;
    final rightFootX = cx + halfSpan;
    final leftBulgeX = cx - bulgeSpan;
    final rightBulgeX = cx + bulgeSpan;

    return Path()
      ..moveTo(leftFootX, baseY)
      // Left wall rises, bulging out past the foot to its widest point.
      ..cubicTo(
        leftFootX,
        baseY - h * 0.22,
        leftBulgeX,
        bulgeY + h * 0.10,
        leftBulgeX,
        bulgeY,
      )
      // Then sweeps sharply back in to the point at the top.
      ..cubicTo(
        leftBulgeX + bulgeSpan * 0.35,
        bulgeY - h * 0.15,
        cx - w * 0.018,
        apexY + h * 0.09,
        cx,
        apexY,
      )
      // Mirror back down the right side.
      ..cubicTo(
        cx + w * 0.018,
        apexY + h * 0.09,
        rightBulgeX - bulgeSpan * 0.35,
        bulgeY - h * 0.15,
        rightBulgeX,
        bulgeY,
      )
      ..cubicTo(
        rightBulgeX,
        bulgeY + h * 0.10,
        rightFootX,
        baseY - h * 0.22,
        rightFootX,
        baseY,
      );
  }

  @override
  bool shouldRepaint(covariant _ArchPainter oldDelegate) =>
      oldDelegate.rim != rim ||
      oldDelegate.glow != glow ||
      oldDelegate.rayRotation != rayRotation ||
      oldDelegate.rayPulse != rayPulse;
}

/// The arch's content: eyebrow label, prayer name, headline, and supporting
/// line — real, crisp text widgets, positioned proportionally to the arch
/// behind them.
class _HeroText extends StatelessWidget {
  final SalahPrayer prayer;

  const _HeroText({required this.prayer});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Padding(
          padding: EdgeInsets.only(
            top: constraints.maxHeight * 0.32,
            left: 28,
            right: 28,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'PRAYER TIME',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.78),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 5,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                prayer.displayName.toUpperCase(),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppTheme.softGold,
                  fontSize: 42,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 3,
                  height: 1.0,
                  shadows: [Shadow(color: Color(0x80C9A24B), blurRadius: 18)],
                ),
              ),
              const SizedBox(height: 26),
              const Text(
                AppStrings.incomingHeadline,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'Georgia',
                  height: 1.18,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                AppStrings.incomingSupportingLine(prayer),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.80),
                  fontSize: 15.5,
                  fontWeight: FontWeight.w500,
                  height: 1.4,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A fixed scatter of tiny stars in the upper sky, each twinkling on its
/// own phase so the field never pulses in unison — real randomness, not a
/// single repeating blink. Purely decorative atmosphere, drawn once per
/// frame as simple blurred dots rather than any bitmap.
class _StarSeed {
  final double dx; // fraction of width, 0..1
  final double dy; // fraction of height, 0..1 (kept to the upper sky)
  final double radius;
  final double phase; // 0..1, offsets this star's twinkle cycle

  const _StarSeed(this.dx, this.dy, this.radius, this.phase);
}

const _starSeeds = <_StarSeed>[
  _StarSeed(0.10, 0.07, 1.6, 0.05),
  _StarSeed(0.22, 0.14, 1.1, 0.42),
  _StarSeed(0.33, 0.05, 1.3, 0.71),
  _StarSeed(0.80, 0.09, 1.7, 0.18),
  _StarSeed(0.90, 0.19, 1.1, 0.63),
  _StarSeed(0.70, 0.04, 1.0, 0.33),
  _StarSeed(0.15, 0.26, 1.2, 0.86),
  _StarSeed(0.60, 0.15, 0.9, 0.50),
  _StarSeed(0.87, 0.30, 1.4, 0.08),
  _StarSeed(0.45, 0.08, 1.0, 0.95),
  _StarSeed(0.05, 0.33, 1.1, 0.27),
  _StarSeed(0.95, 0.40, 1.0, 0.60),
];

class _StarFieldPainter extends CustomPainter {
  final Animation<double> twinkle;

  _StarFieldPainter({required this.twinkle}) : super(repaint: twinkle);

  @override
  void paint(Canvas canvas, Size size) {
    for (final star in _starSeeds) {
      final cycle = (twinkle.value + star.phase) % 1.0;
      final glow = 0.35 + 0.55 * (0.5 + 0.5 * math.sin(cycle * 2 * math.pi));
      final center = Offset(star.dx * size.width, star.dy * size.height);
      canvas.drawCircle(
        center,
        star.radius * 2.2,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.22 * glow)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.4),
      );
      canvas.drawCircle(
        center,
        star.radius,
        Paint()..color = Colors.white.withValues(alpha: 0.75 * glow),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _StarFieldPainter oldDelegate) => false;
}

/// A soft, glowing wash of light that rises from the very bottom of the
/// screen toward the middle, blooming as it climbs and fading away before
/// the next pulse begins beneath it — the "magical aura" layered over the
/// whole scene, buttons and all, rather than confined to one section.
class _RisingAuraGlow extends StatelessWidget {
  final Animation<double> controller;
  final Color color;

  const _RisingAuraGlow({required this.controller, required this.color});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final t = controller.value;
        // Travels from just below the bottom edge (1.35) up to just past
        // the screen's middle (-0.25).
        final centerY = 1.35 - 1.6 * Curves.easeOut.transform(t);
        // Blooms in, holds briefly, fades out — rather than a flat pulse.
        final fade = math.sin((t.clamp(0.0, 1.0)) * math.pi);
        return Align(
          alignment: Alignment(0, centerY),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 520,
                height: 520,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Colors.white.withValues(alpha: 0.22 * fade),
                      AppTheme.softGold.withValues(alpha: 0.26 * fade),
                      color.withValues(alpha: 0.16 * fade),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.25, 0.55, 1.0],
                  ),
                ),
              ),
              // A brighter sparking core at the heart of the bloom.
              Container(
                width: 90,
                height: 90,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Colors.white.withValues(alpha: 0.55 * fade),
                      Colors.white.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The bottom action row: Decline / Answer, over a warm gradient panel that
/// continues the art's atmosphere, with light radiating up from the very
/// bottom edge — like the source artwork's own sunburst, carried through.
class _ActionPanel extends StatelessWidget {
  final PrayerPalette theme;
  final Color gradientTop;
  final Color gradientBottom;
  final Animation<double> pulse;
  final Animation<double> shake;
  final Animation<double> ripple;
  final Animation<double> sunburst;
  final VoidCallback onAnswer;
  final VoidCallback onDecline;

  const _ActionPanel({
    required this.theme,
    required this.gradientTop,
    required this.gradientBottom,
    required this.pulse,
    required this.shake,
    required this.ripple,
    required this.sunburst,
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
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: _SunburstGlow(sunburst: sunburst, color: theme.accent),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(40, 10, 40, 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _CallAction(
                    label: AppStrings.declineLabel,
                    labelColor: Colors.white,
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
        ],
      ),
    );
  }
}

/// A soft wash of light rising from the very bottom edge of the panel —
/// no distinct "sun" disc, no rays, just a gentle glow that breathes
/// (grows/brightens, then eases back) so it reads as light drifting
/// upward rather than an object sitting mid-screen.
class _SunburstGlow extends StatelessWidget {
  final Animation<double> sunburst;
  final Color color;

  const _SunburstGlow({required this.sunburst, required this.color});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: sunburst,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(sunburst.value);
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.bottomCenter,
              // Anchored exactly on the bottom edge — the glow's radius
              // breathes outward/upward, it never detaches into a sphere.
              radius: 0.95 + 0.25 * t,
              colors: [
                Colors.white.withValues(alpha: 0.30 + 0.14 * t),
                color.withValues(alpha: 0.26 + 0.12 * t),
                color.withValues(alpha: 0.10 + 0.04 * t),
                Colors.transparent,
              ],
              stops: const [0.0, 0.32, 0.65, 1.0],
            ),
          ),
        );
      },
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
///
/// Sized to match [_AnswerButton] and given a soft outer halo + a bright
/// rim so it reads clearly as a distinct, tappable button rather than a
/// flat sticker on top of the panel's own gradient.
class _DeclineButton extends StatelessWidget {
  final VoidCallback onTap;

  const _DeclineButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFE23E3E);
    return SizedBox(
      width: 108,
      height: 108,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Soft outer halo for contrast against the gradient panel.
          Container(
            width: 108,
            height: 108,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  red.withValues(alpha: 0.28),
                  red.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.55),
                width: 1.4,
              ),
              boxShadow: [
                BoxShadow(
                  color: red.withValues(alpha: 0.5),
                  blurRadius: 20,
                  spreadRadius: 1,
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
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
                  width: 82,
                  height: 82,
                  child: Icon(Icons.call_end, size: 34, color: Colors.white),
                ),
              ),
            ),
          ),
        ],
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
                    Colors.white,
                    baseRadius: 48,
                    maxRadius: 75,
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
          child: Transform.scale(scale: 1.0 + 0.05 * p, child: child),
        );
      },
      child: SizedBox(
        width: 112,
        height: 112,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Soft outer halo for contrast against the panel's own warm
            // gradient — without it the button nearly vanished into it.
            AnimatedBuilder(
              animation: pulse,
              builder: (context, _) {
                final p = Curves.easeInOut.transform(pulse.value);
                return Container(
                  width: 112,
                  height: 112,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        Colors.white.withValues(alpha: 0.30 + 0.12 * p),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                );
              },
            ),
            AnimatedBuilder(
              animation: pulse,
              builder: (context, child) {
                final p = Curves.easeInOut.transform(pulse.value);
                return Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.7),
                      width: 1.6,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: theme.accent.withValues(alpha: 0.45 + 0.25 * p),
                        blurRadius: 22 + 16 * p,
                        spreadRadius: 2 + 5 * p,
                      ),
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.22),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: child,
                );
              },
              child: Material(
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: Ink(
                  width: 82,
                  height: 82,
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
                    child: Icon(Icons.call, size: 34, color: theme.onAccent),
                  ),
                ),
              ),
            ),
          ],
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
