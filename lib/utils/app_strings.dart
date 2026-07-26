import '../models/salah_prayer.dart';

/// Central place for all user-facing copy.
///
/// Religious/UX rules enforced here:
/// - Never "Call from Allah" or anything implying a literal phone call.
/// - The incoming screen always shows exactly two actions: Answer and
///   Decline. This conscious decision at every prayer is the app's core
///   philosophy. "Decline" is a label only — its behavior is a respectful
///   snooze, never a rejection.
/// - Incoming screen shows exactly one supporting line (prayer-specific or
///   fallback) — never both — and no guilt-heavy warning text.
class AppStrings {
  AppStrings._();

  static const String appTitle = 'Allah Invites You to Salah';

  // Incoming call screen permanent title.
  static const String incomingCallTitle = 'Allah Is Calling';

  // Notification copy.
  static const String notificationTitle = 'Allah Invites You to Salah';

  static String prayerEnteredBody(String prayerName) =>
      '$prayerName has entered';

  // Incoming call screen: exactly one supporting line — prayer-specific
  // when known, otherwise the generic fallback. Never both at once.
  static const String supportingLineFallback =
      'Come to prayer. Come to success.';
  static const String supportingLineFajr = 'Prayer is better than sleep.';
  static const String supportingLineDhuhr =
      'Pause the dunya. Stand before your Lord.';
  static const String supportingLineAsr =
      'Do not let the day pass without answering.';
  static const String supportingLineMaghrib =
      'The sun has set. Return to your Lord.';
  static const String supportingLineIsha =
      'End your day standing before Allah.';

  /// Single hopeful supporting line for the incoming call screen.
  static String incomingSupportingLine(SalahPrayer prayer) {
    switch (prayer) {
      case SalahPrayer.fajr:
        return supportingLineFajr;
      case SalahPrayer.dhuhr:
        return supportingLineDhuhr;
      case SalahPrayer.asr:
        return supportingLineAsr;
      case SalahPrayer.maghrib:
        return supportingLineMaghrib;
      case SalahPrayer.isha:
        return supportingLineIsha;
    }
  }

  // User-requested Decline snooze copy. Neutral: never claims the prayer
  // window is still open (the window may close before the snooze fires).
  static const String snoozeTitle = 'Your Salah Reminder';

  static String snoozeBody(String prayerName) => 'Return for $prayerName.';

  // Automatic missed-prayer follow-up copy. Only used while the prayer
  // window is verifiably still open (scheduled strictly before the next
  // prayer enters).
  static const String followUpTitle = 'You have not answered yet';

  static String followUpBody(String prayerName) =>
      '$prayerName time is still open.';

  // Safety notification fired only if the app has not refreshed its
  // reminder schedule before the scheduled window runs out.
  static const String refreshReminderTitle =
      'Open the app to refresh salah reminders';
  static const String refreshReminderBody =
      'Your upcoming salah reminders need to be refreshed.';

  // Buttons. Answer and Decline are used on the incoming call screen and as
  // notification action buttons in the system shade. "Pray Now" is the
  // notification equivalent of Answer.
  static const String prayNow = 'Pray Now';
  static const String answer = 'Answer';
  static const String declineLabel = 'Decline';

  /// iOS notification category label for the secondary action (same id as Decline).
  static const String dismiss = 'Dismiss';

  // Gentle responses.
  static const String mayAllahAccept = 'May Allah accept your salah.';

  static String snoozeConfirmation(int minutes) =>
      'We will remind you again in $minutes minutes, in shaa Allah.';

  // Generic snooze copy, used when the prayer window may have closed by the
  // time the snooze fires (never claim "[Prayer] time is still open" then).
  static const String genericReminderTitle = 'Salah reminder';
  static const String genericReminderBody = 'Your salah reminder.';

  // Prayer completion.
  static String didYouComplete(String prayerName) =>
      'Did you complete $prayerName?';
  static const String completionYes = 'Yes';
  static const String completionNotYet = 'Not Yet';

  // Android full-screen intent guidance.
  static const String fullScreenGuidanceTitle = 'Full-screen salah reminders';
  static const String fullScreenGuidanceBody =
      'To make prayer reminders feel like an incoming call, Android requires '
      'one additional permission.\n\n'
      'Without it, you\u2019ll still receive normal notifications, but the '
      'full-screen salah reminder may not appear.';

  // OEM battery reliability guidance.
  static const String batteryGuidanceTitle = 'Keep reminders reliable';
  static const String batteryGuidanceBody =
      'To keep salah reminders reliable, allow background activity and '
      'disable battery restrictions for this app.';

  // Location onboarding.
  static const String useLocationPrompt =
      'Use current location for accurate salah times?';
  static const String searchYourCity = 'Search your city';
  static const String enterCoordinatesManually = 'Enter coordinates manually';

  // Qibla finder.
  static const String qiblaTitle = 'Qibla Finder';
  static const String qiblaAligned = 'You are facing the Qibla';
  static const String qiblaRotateHint = 'Rotate until the arrow points up';
  static const String qiblaNoCompass =
      'Compass not available on this device. Use the bearing below with a '
      'physical compass.';
  static const String qiblaNeedsLocation =
      'Set your location to find the Qibla direction.';
  static const String qiblaCalibrationHint =
      'If the reading seems off, move your phone in a figure-8 motion to '
      'calibrate the compass.';

  static String qiblaBearingLine(int degrees, String compassPoint) =>
      'Qibla is $degrees\u00B0 $compassPoint of true North';

  static String qiblaDistanceLine(int km) => '$km km to the Kaaba, Makkah';

  // Quran reading module.
  static const String quranTitle = 'Quran';
  static const String quranDailyGoal = 'Daily Goal';
  static const String quranEditGoal = 'Set daily goal';
  static const String quranEditGoalHint = 'Verses per day';
  static const String quranContinueReading = 'Continue Reading';
  static const String quranQuickAccess = 'Quick Access';
  static const String quranRecentlyRead = 'Recently Read';
  static const String quranAllSurahs = 'All Surahs';
  static const String quranBySurah = 'Surah';
  static const String quranByJuz = 'Juz';
  static const String quranStatsToday = 'Today';
  static const String quranStatsWeek = 'This Week';
  static const String quranStatsAllTime = 'All Time';
  static const String quranBookmarks = 'Bookmarks';
  static const String quranFavorites = 'Favorites';
  static const String quranNoBookmarks = 'No bookmarks yet.';
  static const String quranNoFavorites = 'No favorites yet.';
  static const String quranTafsir = 'Tafsir';
  static const String quranTafsirUnavailable =
      'Tafsir for this verse is not available offline yet. Connect to the '
      'internet once to download it.';
  static const String quranFullTitle = 'Full Quran';
  static const String quranFullSubtitle =
      'Read continuously from Al-Fatihah to An-Nas';
  static const String quranJumpToSurah = 'Jump to surah';
  static const String quranLoadError =
      'Could not load the Quran text. Check your internet connection and '
      'try again. Previously opened surahs stay available offline.';
  static const String quranRetry = 'Retry';
  static const String quranGoalReached =
      'Daily goal reached, may Allah accept.';

  static String quranVersesProgress(int read, int goal) =>
      '$read of $goal verses today';

  static String quranHasanatNote(int hasanat) =>
      '+$hasanat hasanat, in shaa Allah';

  // Disclaimer.
  static const String disclaimer =
      'Prayer times are estimates. Please verify with your local masjid.';

  // Test notification.
  static const String testNotificationBody =
      'This is a test reminder. Your salah reminders are working.';
}
