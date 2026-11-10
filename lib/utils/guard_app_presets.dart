import '../services/app_guard_service.dart';

/// Quick-select helpers for the App Guard picker. Phone / default SMS are
/// already excluded by the native installed-apps list; these presets also
/// leave common messaging apps alone when the user picks "everything except
/// calls & messages".
class GuardAppPresets {
  GuardAppPresets._();

  /// Messaging apps we keep reachable for the "except phone & messaging"
  /// preset (dialer / default SMS are already omitted by native code).
  static const messagingPackages = <String>{
    'com.whatsapp',
    'com.whatsapp.w4b',
    'org.telegram.messenger',
    'org.telegram.messenger.web',
    'org.thoughtcrime.securesms', // Signal
    'com.google.android.apps.messaging',
    'com.samsung.android.messaging',
    'com.android.mms',
    'com.android.messaging',
    'com.facebook.orca', // Messenger
    'com.facebook.mlite',
    'com.skype.raider',
    'com.viber.voip',
    'com.google.android.apps.dynamite', // Google Chat
    'com.microsoft.teams',
    'com.slack',
  };

  /// Well-known distraction / social packages for devices that don't set
  /// [ApplicationInfo.CATEGORY_SOCIAL] (common on sideloaded / older apps).
  static const knownSocialPackages = <String>{
    'com.instagram.android',
    'com.facebook.katana',
    'com.facebook.lite',
    'com.twitter.android',
    'com.zhiliaoapp.musically', // TikTok
    'com.ss.android.ugc.trill', // TikTok alt
    'com.snapchat.android',
    'com.reddit.frontpage',
    'com.google.android.youtube',
    'com.linkedin.android',
    'com.pinterest',
    'com.tumblr',
    'com.bereal.ft',
    'com.discord',
    'tv.twitch.android.app',
    'com.netflix.mediaclient',
    'com.amazon.avod.thirdpartyclient',
    'com.hulu.plus',
    'com.disney.disneyplus',
    'com.spotify.music',
    'com.imo.android.imoim',
  };

  static const socialCategories = <String>{'social', 'video', 'game', 'audio'};

  /// Every launchable app except phone/SMS (already filtered) and messaging.
  static Set<String> everythingExceptPhoneAndMessaging(
    List<GuardableApp> apps,
  ) {
    return apps
        .where((a) => !messagingPackages.contains(a.package))
        .map((a) => a.package)
        .toSet();
  }

  /// Social / entertainment: Play category match or known package list.
  static Set<String> socialAndEntertainment(List<GuardableApp> apps) {
    return apps
        .where(
          (a) =>
              socialCategories.contains(a.category) ||
              knownSocialPackages.contains(a.package),
        )
        .map((a) => a.package)
        .toSet();
  }
}
