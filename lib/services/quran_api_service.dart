import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/quran_models.dart';

/// Fetches Quran text from the AlQuran Cloud API and caches responses on
/// disk so previously opened surahs read instantly and work offline.
///
/// One request per surah returns Arabic (quran-uthmani), English
/// (en.sahih / Sahih International) and transliteration together.
class QuranApiService {
  QuranApiService._();

  static final QuranApiService instance = QuranApiService._();

  static const String _base = 'https://api.alquran.cloud/v1';
  static const Duration _timeout = Duration(seconds: 20);

  Future<Directory> _cacheDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/quran_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<String?> _readCache(String name) async {
    try {
      final file = File('${(await _cacheDir()).path}/$name');
      if (await file.exists()) {
        return await file.readAsString();
      }
    } catch (_) {
      // Cache read failures fall through to a network fetch.
    }
    return null;
  }

  Future<void> _writeCache(String name, String content) async {
    try {
      final file = File('${(await _cacheDir()).path}/$name');
      await file.writeAsString(content);
    } catch (_) {
      // Caching is best-effort.
    }
  }

  Future<Map<String, dynamic>> _getJson(String url) async {
    final response = await http.get(Uri.parse(url)).timeout(_timeout);
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode} for $url');
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    if (decoded['code'] != 200) {
      throw HttpException('API error ${decoded['code']} for $url');
    }
    return decoded;
  }

  String? _bismillahCache;

  /// Exact Uthmani Bismillah, taken verbatim from the API (Al-Fatihah,
  /// verse 1). Used to split the Bismillah off verse 1 of other surahs,
  /// where the quran-uthmani edition embeds it as a prefix.
  Future<String> fetchBismillah() async {
    if (_bismillahCache != null) return _bismillahCache!;
    final fatihah = await fetchSurah(1);
    return _bismillahCache = fatihah.verses.first.arabic.trim();
  }

  /// Metadata for all 114 surahs (names, translations, verse counts).
  Future<List<SurahMeta>> fetchSurahList() async {
    const cacheName = 'surah_list.json';
    final cached = await _readCache(cacheName);
    if (cached != null) {
      final list = jsonDecode(cached) as List<dynamic>;
      return list
          .map((e) => SurahMeta.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    final decoded = await _getJson('$_base/surah');
    final data = decoded['data'] as List<dynamic>;
    final metas =
        data.map((e) => SurahMeta.fromJson(e as Map<String, dynamic>)).toList();
    await _writeCache(
      cacheName,
      jsonEncode(metas.map((m) => m.toJson()).toList()),
    );
    return metas;
  }

  /// The 30 juz with their starting surah and verse.
  Future<List<JuzMeta>> fetchJuzList() async {
    const cacheName = 'juz_list.json';
    List<dynamic>? refs;
    final cached = await _readCache(cacheName);
    if (cached != null) {
      refs = jsonDecode(cached) as List<dynamic>;
    } else {
      final decoded = await _getJson('$_base/meta');
      final data = decoded['data'] as Map<String, dynamic>;
      final juzs = data['juzs'] as Map<String, dynamic>;
      refs = juzs['references'] as List<dynamic>;
      await _writeCache(cacheName, jsonEncode(refs));
    }
    return [
      for (var i = 0; i < refs.length; i++)
        JuzMeta(
          number: i + 1,
          startSurah: (refs[i] as Map<String, dynamic>)['surah'] as int,
          startVerse: (refs[i] as Map<String, dynamic>)['ayah'] as int,
        ),
    ];
  }

  /// Full surah content: Arabic, English translation and transliteration.
  Future<SurahContent> fetchSurah(int number) async {
    final cacheName = 'surah_$number.json';
    Map<String, dynamic>? decoded;
    final cached = await _readCache(cacheName);
    if (cached != null) {
      decoded = jsonDecode(cached) as Map<String, dynamic>;
    } else {
      decoded = await _getJson(
        '$_base/surah/$number/editions/quran-uthmani,en.sahih,en.transliteration',
      );
      await _writeCache(cacheName, jsonEncode(decoded));
    }

    final editions = decoded['data'] as List<dynamic>;
    final arabicEdition = editions[0] as Map<String, dynamic>;
    final translationEdition = editions[1] as Map<String, dynamic>;
    final transliterationEdition =
        editions.length > 2 ? editions[2] as Map<String, dynamic> : null;

    final meta = SurahMeta.fromJson(arabicEdition);
    final arabicAyahs = arabicEdition['ayahs'] as List<dynamic>;
    final translationAyahs = translationEdition['ayahs'] as List<dynamic>;
    final transliterationAyahs =
        transliterationEdition?['ayahs'] as List<dynamic>?;

    final verses = <QuranVerse>[];
    for (var i = 0; i < arabicAyahs.length; i++) {
      final a = arabicAyahs[i] as Map<String, dynamic>;
      final t =
          i < translationAyahs.length
              ? translationAyahs[i] as Map<String, dynamic>
              : null;
      final tr =
          transliterationAyahs != null && i < transliterationAyahs.length
              ? transliterationAyahs[i] as Map<String, dynamic>
              : null;
      verses.add(
        QuranVerse(
          globalNumber: a['number'] as int,
          numberInSurah: a['numberInSurah'] as int,
          page: a['page'] as int? ?? 0,
          juz: a['juz'] as int? ?? 0,
          arabic: a['text'] as String,
          translation: t?['text'] as String? ?? '',
          transliteration: tr?['text'] as String? ?? '',
        ),
      );
    }
    return SurahContent(meta: meta, verses: verses);
  }
}
