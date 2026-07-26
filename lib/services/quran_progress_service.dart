import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Statistics period for the hub dashboard.
enum QuranStatsPeriod { today, week, allTime }

class QuranStats {
  final int versesRead;
  final int hasanat;
  final int secondsReading;
  final int pages;
  final int surahsFinished;
  final int sessions;

  const QuranStats({
    this.versesRead = 0,
    this.hasanat = 0,
    this.secondsReading = 0,
    this.pages = 0,
    this.surahsFinished = 0,
    this.sessions = 0,
  });
}

class QuranPosition {
  final int surah;
  final int verse;
  final String surahName;

  const QuranPosition({
    required this.surah,
    required this.verse,
    required this.surahName,
  });

  Map<String, dynamic> toJson() => {
    'surah': surah,
    'verse': verse,
    'name': surahName,
  };

  factory QuranPosition.fromJson(Map<String, dynamic> json) => QuranPosition(
    surah: json['surah'] as int,
    verse: json['verse'] as int,
    surahName: json['name'] as String? ?? '',
  );
}

/// Persists all Quran reading progress in SharedPreferences:
/// daily goal, per-day reading records (verses, hasanat, time, pages,
/// sessions), finished surahs, bookmarks, favorites, recently read and
/// the last reading position.
///
/// Hasanat follows the teaching that every letter recited earns ten
/// rewards: Arabic letters are counted per verse and multiplied by 10.
class QuranProgressService {
  QuranProgressService._();

  static final QuranProgressService instance = QuranProgressService._();

  static const _keyGoal = 'quran_daily_goal';
  static const _keyDaily = 'quran_daily_records';
  static const _keyReadToday = 'quran_read_today';
  static const _keyPages = 'quran_pages';
  static const _keySurahsDone = 'quran_surahs_done';
  static const _keyLastRead = 'quran_last_read';
  static const _keyFullQuran = 'quran_full_position';
  static const _keyBookmarks = 'quran_bookmarks';
  static const _keyFavorites = 'quran_favorites';
  static const _keyRecent = 'quran_recent';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// Serializes mutating operations. Verse-read events fire rapidly while
  /// scrolling; without this, concurrent read-modify-write cycles on the
  /// daily-records blob overwrite each other and lose counts.
  Future<void> _queue = Future.value();

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  static final RegExp _arabicLetter = RegExp(r'[\u0621-\u064A]');

  /// Hasanat for one verse: Arabic letter count x 10.
  static int hasanatForText(String arabicText) =>
      _arabicLetter.allMatches(arabicText).length * 10;

  String _dateKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String get _todayKey => _dateKey(DateTime.now());

  // ---------------------------------------------------------------- Goal

  Future<int> getDailyGoal() async => (await _p).getInt(_keyGoal) ?? 10;

  Future<void> setDailyGoal(int goal) async =>
      (await _p).setInt(_keyGoal, goal.clamp(1, 1000));

  // ------------------------------------------------------- Daily records

  Future<Map<String, dynamic>> _dailyRecords() async {
    final raw = (await _p).getString(_keyDaily);
    if (raw == null) return {};
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> _saveDailyRecords(Map<String, dynamic> records) async {
    // Prune to the most recent 60 days to keep the blob small. All-time
    // totals are preserved separately via pages/surah sets and summing
    // happens before pruning ever matters (totals accumulate in records
    // only for period stats).
    final keys = records.keys.toList()..sort();
    while (keys.length > 60) {
      records.remove(keys.removeAt(0));
    }
    await (await _p).setString(_keyDaily, jsonEncode(records));
  }

  Future<Map<String, dynamic>> _recordFor(
    Map<String, dynamic> records,
    String dateKey,
  ) async {
    return (records[dateKey] as Map<String, dynamic>?) ??
        {'v': 0, 'h': 0, 's': 0, 'n': 0, 'p': 0, 'f': 0};
  }

  // ---------------------------------------------------- Read verse dedupe

  /// Set of "surah:verse" keys already counted today.
  Future<Set<String>> _readToday() async {
    final raw = (await _p).getString(_keyReadToday);
    if (raw == null) return {};
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    if (decoded['date'] != _todayKey) return {};
    return ((decoded['keys'] as List<dynamic>).cast<String>()).toSet();
  }

  Future<void> _saveReadToday(Set<String> keys) async {
    await (await _p).setString(
      _keyReadToday,
      jsonEncode({'date': _todayKey, 'keys': keys.toList()}),
    );
  }

  // ------------------------------------------------------------- Recording

  /// Records one verse as read. Returns true if it was new for today
  /// (i.e. counted toward the goal).
  Future<bool> recordVerseRead({
    required int surah,
    required int verse,
    required String arabicText,
    required int page,
  }) {
    return _synchronized(
      () => _recordVerseRead(
        surah: surah,
        verse: verse,
        arabicText: arabicText,
        page: page,
      ),
    );
  }

  Future<bool> _recordVerseRead({
    required int surah,
    required int verse,
    required String arabicText,
    required int page,
  }) async {
    final key = '$surah:$verse';
    final readToday = await _readToday();
    if (readToday.contains(key)) return false;
    readToday.add(key);
    await _saveReadToday(readToday);

    final records = await _dailyRecords();
    final today = await _recordFor(records, _todayKey);
    today['v'] = (today['v'] as int) + 1;
    today['h'] = (today['h'] as int) + hasanatForText(arabicText);

    // Distinct pages: first time a page is ever touched it counts for
    // that day's record and the all-time set.
    final pages = ((await _p).getStringList(_keyPages) ?? []).toSet();
    if (page > 0 && !pages.contains('$page')) {
      pages.add('$page');
      await (await _p).setStringList(_keyPages, pages.toList());
      today['p'] = (today['p'] as int? ?? 0) + 1;
    }

    records[_todayKey] = today;
    await _saveDailyRecords(records);
    return true;
  }

  Future<void> addReadingSession(Duration duration) {
    return _synchronized(() async {
      if (duration.inSeconds < 5) return;
      final records = await _dailyRecords();
      final today = await _recordFor(records, _todayKey);
      today['s'] = (today['s'] as int) + duration.inSeconds;
      today['n'] = (today['n'] as int) + 1;
      records[_todayKey] = today;
      await _saveDailyRecords(records);
    });
  }

  /// Marks a surah finished (user reached its last verse).
  Future<void> markSurahFinished(int surah) {
    return _synchronized(() async {
      final done = ((await _p).getStringList(_keySurahsDone) ?? []).toSet();
      if (done.contains('$surah')) return;
      done.add('$surah');
      await (await _p).setStringList(_keySurahsDone, done.toList());
      final records = await _dailyRecords();
      final today = await _recordFor(records, _todayKey);
      today['f'] = (today['f'] as int? ?? 0) + 1;
      records[_todayKey] = today;
      await _saveDailyRecords(records);
    });
  }

  // ---------------------------------------------------------------- Stats

  Future<QuranStats> statsFor(QuranStatsPeriod period) async {
    final records = await _dailyRecords();

    Iterable<Map<String, dynamic>> selected;
    switch (period) {
      case QuranStatsPeriod.today:
        selected = [await _recordFor(records, _todayKey)];
      case QuranStatsPeriod.week:
        final now = DateTime.now();
        selected = [
          for (var i = 0; i < 7; i++)
            (records[_dateKey(now.subtract(Duration(days: i)))]
                    as Map<String, dynamic>?) ??
                const {},
        ];
      case QuranStatsPeriod.allTime:
        selected = records.values.cast<Map<String, dynamic>>();
    }

    var v = 0, h = 0, s = 0, n = 0, p = 0, f = 0;
    for (final r in selected) {
      v += (r['v'] as int? ?? 0);
      h += (r['h'] as int? ?? 0);
      s += (r['s'] as int? ?? 0);
      n += (r['n'] as int? ?? 0);
      p += (r['p'] as int? ?? 0);
      f += (r['f'] as int? ?? 0);
    }

    if (period == QuranStatsPeriod.allTime) {
      // Sets are authoritative for all-time pages/surah counts (they
      // survive daily record pruning).
      p = ((await _p).getStringList(_keyPages) ?? []).length;
      f = ((await _p).getStringList(_keySurahsDone) ?? []).length;
    }

    return QuranStats(
      versesRead: v,
      hasanat: h,
      secondsReading: s,
      pages: p,
      surahsFinished: f,
      sessions: n,
    );
  }

  /// Whether the user read anything on each of the last 7 days
  /// (index 0 = 6 days ago ... index 6 = today).
  Future<List<bool>> weeklyActivity() async {
    final records = await _dailyRecords();
    final now = DateTime.now();
    return [
      for (var i = 6; i >= 0; i--)
        ((records[_dateKey(now.subtract(Duration(days: i)))]
                        as Map<String, dynamic>?)?['v']
                    as int? ??
                0) >
            0,
    ];
  }

  // ------------------------------------------------------------- Position

  Future<QuranPosition?> getLastRead() async {
    final raw = (await _p).getString(_keyLastRead);
    if (raw == null) return null;
    return QuranPosition.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> setLastRead(QuranPosition position) async {
    await (await _p).setString(_keyLastRead, jsonEncode(position.toJson()));
  }

  /// Last visible position in the continuous full-Quran scroll,
  /// as (surah, verse). Tracked separately from the surah reader.
  Future<(int, int)?> getFullQuranPosition() async {
    final raw = (await _p).getString(_keyFullQuran);
    if (raw == null) return null;
    final parts = raw.split(':');
    if (parts.length != 2) return null;
    final surah = int.tryParse(parts[0]);
    final verse = int.tryParse(parts[1]);
    if (surah == null || verse == null) return null;
    return (surah, verse);
  }

  Future<void> setFullQuranPosition(int surah, int verse) async {
    await (await _p).setString(_keyFullQuran, '$surah:$verse');
  }

  // ------------------------------------------- Bookmarks/favorites/recent

  Future<List<QuranPosition>> _positionList(String key) async {
    final raw = (await _p).getString(key);
    if (raw == null) return [];
    return (jsonDecode(raw) as List<dynamic>)
        .map((e) => QuranPosition.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> _savePositionList(String key, List<QuranPosition> list) async {
    await (await _p).setString(
      key,
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  Future<List<QuranPosition>> getBookmarks() => _positionList(_keyBookmarks);

  Future<bool> isBookmarked(int surah, int verse) async =>
      (await getBookmarks()).any((b) => b.surah == surah && b.verse == verse);

  Future<bool> toggleBookmark(QuranPosition position) async {
    final list = await getBookmarks();
    final existing = list.indexWhere(
      (b) => b.surah == position.surah && b.verse == position.verse,
    );
    if (existing >= 0) {
      list.removeAt(existing);
      await _savePositionList(_keyBookmarks, list);
      return false;
    }
    list.insert(0, position);
    await _savePositionList(_keyBookmarks, list);
    return true;
  }

  Future<List<QuranPosition>> getFavorites() => _positionList(_keyFavorites);

  Future<bool> isFavorite(int surah, int verse) async =>
      (await getFavorites()).any((b) => b.surah == surah && b.verse == verse);

  Future<bool> toggleFavorite(QuranPosition position) async {
    final list = await getFavorites();
    final existing = list.indexWhere(
      (b) => b.surah == position.surah && b.verse == position.verse,
    );
    if (existing >= 0) {
      list.removeAt(existing);
      await _savePositionList(_keyFavorites, list);
      return false;
    }
    list.insert(0, position);
    await _savePositionList(_keyFavorites, list);
    return true;
  }

  Future<List<QuranPosition>> getRecent() => _positionList(_keyRecent);

  Future<void> addRecent(QuranPosition position) {
    return _synchronized(() async {
      final list = await getRecent();
      list.removeWhere((r) => r.surah == position.surah);
      list.insert(0, position);
      while (list.length > 10) {
        list.removeLast();
      }
      await _savePositionList(_keyRecent, list);
    });
  }
}
