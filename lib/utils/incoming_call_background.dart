import '../models/salah_prayer.dart';

/// Illustrated hero artwork shown on the "Allah is calling" screen — one
/// scene per prayer, each already carrying its own title, prayer name, and
/// supporting line baked into the image.
///
/// All five source images share the exact same canvas, [nativeAspect], so
/// the incoming-call screen can crop/scale them identically regardless of
/// device size.
class IncomingCallBackground {
  IncomingCallBackground._();

  /// Source canvas width / height. Used to compute the rendered height of
  /// the artwork at any screen width without needing to decode the image
  /// first.
  static const double nativeAspect = 496 / 1024;

  static String assetFor(SalahPrayer prayer) {
    switch (prayer) {
      case SalahPrayer.fajr:
        return 'assets/incoming_call/fajr.jpg';
      case SalahPrayer.dhuhr:
        return 'assets/incoming_call/dhuhr.jpg';
      case SalahPrayer.asr:
        return 'assets/incoming_call/asr.jpg';
      case SalahPrayer.maghrib:
        return 'assets/incoming_call/maghrib.jpg';
      case SalahPrayer.isha:
        return 'assets/incoming_call/isha.jpg';
    }
  }
}
