import 'dart:async';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/salah_prayer.dart';
import 'utils/app_theme.dart';
import 'widgets/prayer_call_scene.dart';

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
    // Exactly the same scene as the in-app call screen (PrayerCallScene) —
    // only the supporting line differs, to say which app is being held
    // closed. Even while config is still loading the full scene is painted
    // so the user never sits on a blank/spinner-only screen; Answer/Decline
    // are inert until we know which app we're covering.
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: theme.gradientBottom,
        body: PrayerCallScene(
          prayerLabel: _prayerLabel,
          supportingLine:
              _loading
                  ? 'Preparing your reminder…'
                  : '$_blockedAppLabel will stay closed until you '
                      'answer or decline.',
          palette: theme,
          onAnswer: _loading ? () {} : _answer,
          onDecline: _loading ? () {} : _decline,
        ),
      ),
    );
  }
}

