import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Restores normal status/nav bars after immersive screens (incoming call
/// preview, etc.). Leaving immersive / edge-to-edge mid-session was making
/// Settings' ListView fight system insets while scrolling.
void restoreAppSystemUi() {
  SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.manual,
    overlays: SystemUiOverlay.values,
  );
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );
  SystemChrome.setPreferredOrientations(const []);
}
