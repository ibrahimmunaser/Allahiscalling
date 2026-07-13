/// The five daily prayers supported by the app.
enum SalahPrayer {
  fajr('Fajr'),
  dhuhr('Dhuhr'),
  asr('Asr'),
  maghrib('Maghrib'),
  isha('Isha');

  final String displayName;

  const SalahPrayer(this.displayName);

  static SalahPrayer? fromName(String name) {
    for (final p in SalahPrayer.values) {
      if (p.name == name || p.displayName == name) return p;
    }
    return null;
  }
}
