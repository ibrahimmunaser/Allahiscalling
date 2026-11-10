import 'dart:ui' show lerpDouble;

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
  runApp(const GuardApp());
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
  String _blockedAppLabel = 'This app';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
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
    setState(() {
      _prayer = SalahPrayer.fromName(data?['prayer'] as String? ?? '');
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

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: AppTheme.deepGreen,
        body: Center(
          child: CircularProgressIndicator(color: AppTheme.softGold),
        ),
      );
    }
    final prayer = _prayer ?? SalahPrayer.dhuhr;
    final theme = AppTheme.forPrayer(prayer);
    return PopScope(
      // Mirrors the main app's incoming-call screen: only Answer/Decline
      // may leave this screen.
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
                  colors: [theme.gradientTop, theme.gradientMid, theme.gradientBottom],
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
                    prayer.displayName.toUpperCase(),
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
                      '$_blockedAppLabel will stay closed until you answer '
                      'or decline.',
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
                          onTap: _decline,
                          child: _DeclineCircle(onTap: _decline),
                        ),
                        _GuardAction(
                          label: 'Answer',
                          labelColor: theme.softAccent,
                          onTap: _answer,
                          child: _AnswerCircle(onTap: _answer, theme: theme),
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
