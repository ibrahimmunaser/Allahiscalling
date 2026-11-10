import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/salah_prayer.dart';
import 'utils/app_theme.dart';

/// Separate, lightweight Flutter entrypoint for the App Guard block screen
/// (Android only — see `GuardBlockActivity.kt`).
///
/// Deliberately NOT the app's normal `main()`: this runs in its own engine,
/// launched the instant a guarded app is opened during the 15-minute
/// window after a prayer enters, so it must never depend on
/// `AppController`/`PrayerSettingsRepository`/the rest of the app's state —
/// only on what the native side hands it over [_channel].
@pragma('vm:entry-point')
void guardMain() {
  // Own Flutter engine (not the main app's) — bind before runApp so plugins
  // / MethodChannel are ready the moment GuardBlockActivity attaches.
  WidgetsFlutterBinding.ensureInitialized();

  // This isolate has no crash reporting of its own, and a silent exception
  // here previously meant the window just sat on its native splash forever
  // — which looked like a plain black screen in dark mode. Catch anything
  // that escapes the widget tree and at least log it; in release, also make
  // build-time errors visible so a regression is never mistaken for "just
  // black".
  FlutterError.onError = (details) {
    debugPrint('GuardApp FlutterError: ${details.exceptionAsString()}');
    debugPrintStack(stackTrace: details.stack);
  };
  if (kReleaseMode) {
    ErrorWidget.builder = (details) {
      debugPrint('GuardApp ErrorWidget: ${details.exceptionAsString()}');
      return Container(
        color: AppTheme.deepGreen,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: const Text(
          'Allah Is Calling\n(guard screen error — see logs)',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppTheme.ivory, fontSize: 16),
        ),
      );
    };
  }
  runZonedGuarded(
    () => runApp(const GuardApp()),
    (error, stack) {
      debugPrint('GuardApp uncaught zone error: $error');
      debugPrintStack(stackTrace: stack);
    },
  );
}

const MethodChannel _channel = MethodChannel(
  'com.salahinvite.allah_invites_you_to_salah/app_guard_screen',
);

class GuardApp extends StatelessWidget {
  const GuardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: const GuardShieldScreen(),
    );
  }
}

/// Fetches the current prayer/blocked-app config from the native host
/// (pulled via `getConfig` so it works even on a freshly created, not yet
/// warm, engine) and re-reads it on every subsequent `configure` push (a
/// later guard window reusing the same cached engine).
class GuardShieldScreen extends StatefulWidget {
  const GuardShieldScreen({super.key});

  @override
  State<GuardShieldScreen> createState() => _GuardShieldScreenState();
}

class _GuardShieldScreenState extends State<GuardShieldScreen> {
  SalahPrayer? _prayer;
  /// Shown under "Allah Is Calling" — a real prayer name, or a neutral
  /// "Prayer" label when the native side passed a non-prayer string (e.g.
  /// the "Test" demo window).
  String _prayerLabel = 'Prayer';
  String _blockedAppLabel = 'This app';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: AppTheme.deepGreen,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
    _channel.setMethodCallHandler(_handleCall);
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getConfig',
      );
      _applyConfig(result);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<dynamic> _handleCall(MethodCall call) async {
    if (call.method == 'configure') {
      _applyConfig(call.arguments as Map<dynamic, dynamic>?);
    }
    return null;
  }

  void _applyConfig(Map<dynamic, dynamic>? data) {
    if (!mounted) return;
    final raw = (data?['prayer'] as String?)?.trim() ?? '';
    final parsed = SalahPrayer.fromName(raw);
    setState(() {
      _prayer = parsed;
      // Never show "Test" (or any other non-prayer tag) as the big prayer
      // name — fall back to a calm generic label for demo / unknown windows.
      _prayerLabel = parsed?.displayName ?? 'Prayer';
      _blockedAppLabel =
          (data?['blockedAppLabel'] as String?) ??
          (data?['blockedPackage'] as String?) ??
          'This app';
      _loading = false;
    });
  }

  Future<void> _answer() async {
    HapticFeedback.selectionClick();
    try {
      await _channel.invokeMethod('answer');
    } catch (_) {}
  }

  Future<void> _decline() async {
    HapticFeedback.selectionClick();
    try {
      await _channel.invokeMethod('decline');
    } catch (_) {}
  }

  /// Palette for the known prayer, or the brand deep-green look when the
  /// window isn't tied to a specific salah (demo / unknown).
  PrayerPalette get _theme {
    final prayer = _prayer;
    if (prayer != null) return AppTheme.forPrayer(prayer);
    return const PrayerPalette(
      primary: AppTheme.emerald,
      deep: AppTheme.deepGreen,
      accent: AppTheme.gold,
      softAccent: AppTheme.softGold,
      gradientTop: AppTheme.nightBlue,
      gradientMid: AppTheme.deepGreen,
      gradientBottom: AppTheme.emerald,
      onAccent: AppTheme.deepGreen,
      listTint: AppTheme.emerald,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = _theme;
    // Even while config is still loading, paint the real call UI shell so
    // the user never sits on a blank/spinner-only screen — Answer/Decline
    // stay disabled until we know which app we're covering.
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: theme.gradientMid,
        body: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    theme.gradientTop,
                    theme.gradientMid,
                    theme.gradientBottom,
                  ],
                  stops: const [0.0, 0.45, 1.0],
                ),
              ),
            ),
            SafeArea(
              child: Column(
                children: [
                  const Spacer(flex: 2),
                  _RingingAvatar(theme: theme),
                  const SizedBox(height: 28),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      'Allah Is Calling',
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
                  Text(
                    _prayerLabel.toUpperCase(),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: theme.softAccent,
                      fontSize: 36,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 3.5,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Text(
                      _loading
                          ? 'Preparing your reminder…'
                          : '$_blockedAppLabel will stay closed until you '
                              'answer or decline.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppTheme.ivory.withValues(alpha: 0.88),
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                        height: 1.4,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                  const Spacer(flex: 3),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 44),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _GuardAction(
                          label: 'Decline',
                          labelColor: Colors.red.shade300,
                          onTap: _loading ? () {} : _decline,
                          child: _DeclineCircle(
                            onTap: _loading ? () {} : _decline,
                          ),
                        ),
                        _GuardAction(
                          label: 'Answer',
                          labelColor: theme.softAccent,
                          onTap: _loading ? () {} : _answer,
                          child: _AnswerCircle(
                            onTap: _loading ? () {} : _answer,
                            theme: theme,
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
      ),
    );
  }
}

class _RingingAvatar extends StatefulWidget {
  final PrayerPalette theme;
  const _RingingAvatar({required this.theme});

  @override
  State<_RingingAvatar> createState() => _RingingAvatarState();
}

class _RingingAvatarState extends State<_RingingAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    return SizedBox(
      width: 300,
      height: 300,
      child: AnimatedBuilder(
        animation: _controller,
        builder:
            (context, child) =>
                CustomPaint(painter: _RipplePainter(_controller.value, theme.accent), child: child),
        child: Center(
          child: Container(
            width: 132,
            height: 132,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [theme.primary, theme.deep],
              ),
              border: Border.all(color: theme.accent, width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.45),
                  blurRadius: 30,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Icon(Icons.mosque_outlined, size: 60, color: theme.softAccent),
          ),
        ),
      ),
    );
  }
}

class _GuardAction extends StatelessWidget {
  final String label;
  final Color labelColor;
  final VoidCallback onTap;
  final Widget child;

  const _GuardAction({
    required this.label,
    required this.labelColor,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$label prayer guard screen',
      onTap: onTap,
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            child,
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

class _DeclineCircle extends StatelessWidget {
  final VoidCallback onTap;
  const _DeclineCircle({required this.onTap});

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFD32F2F);
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: red.withValues(alpha: 0.38), blurRadius: 18, spreadRadius: 1)],
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

class _AnswerCircle extends StatelessWidget {
  final VoidCallback onTap;
  final PrayerPalette theme;
  const _AnswerCircle({required this.onTap, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Material(
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
    );
  }
}

class _RipplePainter extends CustomPainter {
  final double progress;
  final Color accent;
  _RipplePainter(this.progress, this.accent);

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
          ..color = accent.withValues(alpha: opacity),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RipplePainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.accent != accent;
}
