/// How the user responded to a prayer reminder. Distinct from completion,
/// which is tracked separately (a prayer can be answered but not yet marked
/// complete, or completed without any reminder interaction).
enum PrayerResponseState {
  /// The user pressed Answer (or "Pray Now"): they intend to pray.
  answered,

  /// The user pressed Decline: the configured snooze was requested.
  declined,

  /// The reminder UI was closed without choosing Answer or Decline (e.g.
  /// the full-screen reminder was backed out of). Never treated as Decline:
  /// no snooze is scheduled, and the automatic unanswered follow-up remains.
  ///
  /// Only recorded where the platform genuinely reports the dismissal; a
  /// notification swiped away in the system shade provides no reliable
  /// callback and is deliberately NOT inferred.
  dismissed,
}
