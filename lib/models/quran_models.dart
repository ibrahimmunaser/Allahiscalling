/// Data models for the Quran reading module.
///
/// Verse text and translations come from the AlQuran Cloud API
/// (https://alquran.cloud/api): editions `quran-uthmani` (Arabic) and
/// `en.sahih` (Sahih International English), plus `en.transliteration`.
library;

class SurahMeta {
  final int number;
  final String arabicName;
  final String englishName;
  final String englishTranslation;
  final int verseCount;
  final String revelationType;

  const SurahMeta({
    required this.number,
    required this.arabicName,
    required this.englishName,
    required this.englishTranslation,
    required this.verseCount,
    required this.revelationType,
  });

  factory SurahMeta.fromJson(Map<String, dynamic> json) => SurahMeta(
    number: json['number'] as int,
    arabicName: json['name'] as String,
    englishName: json['englishName'] as String,
    englishTranslation: json['englishNameTranslation'] as String,
    verseCount: json['numberOfAyahs'] as int,
    revelationType: json['revelationType'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'number': number,
    'name': arabicName,
    'englishName': englishName,
    'englishNameTranslation': englishTranslation,
    'numberOfAyahs': verseCount,
    'revelationType': revelationType,
  };
}

class JuzMeta {
  final int number;
  final int startSurah;
  final int startVerse;

  const JuzMeta({
    required this.number,
    required this.startSurah,
    required this.startVerse,
  });
}

class QuranVerse {
  /// Global ayah number across the whole Quran (1..6236).
  final int globalNumber;
  final int numberInSurah;
  final int page;
  final int juz;
  final String arabic;
  final String translation;
  final String transliteration;

  const QuranVerse({
    required this.globalNumber,
    required this.numberInSurah,
    required this.page,
    required this.juz,
    required this.arabic,
    required this.translation,
    required this.transliteration,
  });

  /// Mishary Alafasy recitation hosted by islamic.network CDN.
  String get audioUrl =>
      'https://cdn.islamic.network/quran/audio/128/ar.alafasy/$globalNumber.mp3';
}

class SurahContent {
  final SurahMeta meta;
  final List<QuranVerse> verses;

  const SurahContent({required this.meta, required this.verses});
}
