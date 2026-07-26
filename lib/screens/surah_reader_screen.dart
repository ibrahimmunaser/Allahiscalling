import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';

import '../models/quran_models.dart';
import '../services/quran_api_service.dart';
import '../services/quran_progress_service.dart';
import '../services/tafsir_service.dart';
import '../utils/app_strings.dart';
import '../utils/app_theme.dart';

/// Reads one surah: Arabic, English translation and transliteration per
/// verse, with audio, bookmarks, favorites and expandable tafsir.
///
/// Two modes: a scrolling list of all verses, and a verse-by-verse
/// card mode with forward/back buttons (PageView). Verse-by-verse mode
/// continues across surah boundaries: Next on a surah's last verse plays
/// a short confetti celebration and moves to the next surah's first
/// verse; Previous on verse 1 moves to the previous surah's last verse.
class SurahReaderScreen extends StatefulWidget {
  final int surahNumber;
  final int initialVerse;

  const SurahReaderScreen({
    super.key,
    required this.surahNumber,
    this.initialVerse = 1,
  });

  @override
  State<SurahReaderScreen> createState() => _SurahReaderScreenState();
}

class _SurahReaderScreenState extends State<SurahReaderScreen> {
  static const int _lastSurah = 114;

  final _progress = QuranProgressService.instance;
  final _player = AudioPlayer();
  final Stopwatch _sessionWatch = Stopwatch()..start();
  final ConfettiController _confetti = ConfettiController(
    duration: const Duration(milliseconds: 1600),
  );

  /// Surah currently shown; changes as verse-by-verse mode crosses
  /// surah boundaries.
  late int _surahNumber;

  Future<SurahContent>? _future;
  bool _swipeMode = false;
  PageController? _pageController;
  int _currentPage = 0;

  /// Blocks the nav buttons while the confetti celebration runs.
  bool _celebrating = false;

  /// The An-Nas finish celebration only fires once per visit.
  bool _quranEndCelebrated = false;

  /// Uthmani Bismillah (from the API) used to display it separately
  /// instead of glued to verse 1.
  String? _bismillah;

  /// Verses counted as read during this visit (numberInSurah).
  final Set<int> _readThisSession = {};
  final Set<int> _bookmarked = {};
  final Set<int> _favorited = {};

  int? _playingVerse;
  int _dailyGoal = 10;
  int _readToday = 0;
  bool _goalCelebrated = false;

  @override
  void initState() {
    super.initState();
    _surahNumber = widget.surahNumber;
    _swipeMode = widget.initialVerse > 1;
    _currentPage = (widget.initialVerse - 1).clamp(0, 9999);
    _future = QuranApiService.instance.fetchSurah(_surahNumber);
    _loadState();
    _loadBismillah();
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingVerse = null);
    });
  }

  Future<void> _loadBismillah() async {
    try {
      final bismillah = await QuranApiService.instance.fetchBismillah();
      if (mounted) setState(() => _bismillah = bismillah);
    } catch (_) {
      // Offline with no cache: verse 1 keeps its embedded Bismillah.
    }
  }

  /// True when this surah shows a separate Bismillah line (all except
  /// Al-Fatihah, where it IS verse 1, and At-Tawbah, which has none).
  bool get _showsBismillah =>
      _surahNumber != 1 && _surahNumber != 9 && _bismillah != null;

  /// Verse text with the embedded Bismillah prefix split off verse 1,
  /// since it is rendered as its own centered line.
  String _displayArabic(QuranVerse verse) {
    final bismillah = _bismillah;
    if (verse.numberInSurah == 1 &&
        _showsBismillah &&
        bismillah != null &&
        verse.arabic.startsWith(bismillah)) {
      final stripped = verse.arabic.substring(bismillah.length).trimLeft();
      if (stripped.isNotEmpty) return stripped;
    }
    return verse.arabic;
  }

  Widget _buildBismillahLine() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Text(
        _bismillah!,
        textAlign: TextAlign.center,
        textDirection: TextDirection.rtl,
        style: const TextStyle(
          fontSize: 24,
          height: 1.8,
          color: AppTheme.deepGreen,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Future<void> _loadState() async {
    _dailyGoal = await _progress.getDailyGoal();
    final todayStats = await _progress.statsFor(QuranStatsPeriod.today);
    _readToday = todayStats.versesRead;
    _goalCelebrated = _readToday >= _dailyGoal;
    final bookmarks = await _progress.getBookmarks();
    final favorites = await _progress.getFavorites();
    if (!mounted) return;
    setState(() {
      _bookmarked
        ..clear()
        ..addAll(
          bookmarks.where((b) => b.surah == _surahNumber).map((b) => b.verse),
        );
      _favorited
        ..clear()
        ..addAll(
          favorites.where((f) => f.surah == _surahNumber).map((f) => f.verse),
        );
    });
  }

  @override
  void dispose() {
    _player.dispose();
    _pageController?.dispose();
    _confetti.dispose();
    _sessionWatch.stop();
    // Fire-and-forget: persist the reading session time.
    _progress.addReadingSession(_sessionWatch.elapsed);
    super.dispose();
  }

  Future<void> _onVerseSeen(SurahContent content, QuranVerse verse) async {
    if (_readThisSession.contains(verse.numberInSurah)) return;
    _readThisSession.add(verse.numberInSurah);

    final position = QuranPosition(
      surah: _surahNumber,
      verse: verse.numberInSurah,
      surahName: content.meta.englishName,
    );
    unawaited(_progress.setLastRead(position));
    unawaited(_progress.addRecent(position));

    final counted = await _progress.recordVerseRead(
      surah: _surahNumber,
      verse: verse.numberInSurah,
      arabicText: verse.arabic,
      page: verse.page,
    );
    if (counted) {
      _readToday += 1;
      if (_readToday >= _dailyGoal && !_goalCelebrated && mounted) {
        _goalCelebrated = true;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(AppStrings.quranGoalReached)),
        );
      }
    }
    if (verse.numberInSurah == content.meta.verseCount) {
      unawaited(_progress.markSurahFinished(_surahNumber));
    }
  }

  Future<void> _toggleAudio(QuranVerse verse) async {
    if (_playingVerse == verse.numberInSurah) {
      await _player.stop();
      setState(() => _playingVerse = null);
      return;
    }
    setState(() => _playingVerse = verse.numberInSurah);
    try {
      await _player.stop();
      await _player.play(UrlSource(verse.audioUrl));
    } catch (_) {
      if (mounted) setState(() => _playingVerse = null);
    }
  }

  Future<void> _toggleBookmark(SurahContent content, QuranVerse verse) async {
    final added = await _progress.toggleBookmark(
      QuranPosition(
        surah: _surahNumber,
        verse: verse.numberInSurah,
        surahName: content.meta.englishName,
      ),
    );
    if (!mounted) return;
    setState(() {
      added
          ? _bookmarked.add(verse.numberInSurah)
          : _bookmarked.remove(verse.numberInSurah);
    });
  }

  Future<void> _toggleFavorite(SurahContent content, QuranVerse verse) async {
    final added = await _progress.toggleFavorite(
      QuranPosition(
        surah: _surahNumber,
        verse: verse.numberInSurah,
        surahName: content.meta.englishName,
      ),
    );
    if (!mounted) return;
    setState(() {
      added
          ? _favorited.add(verse.numberInSurah)
          : _favorited.remove(verse.numberInSurah);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SurahContent>(
      future: _future,
      builder: (context, snapshot) {
        final content = snapshot.data;
        return Scaffold(
          appBar: AppBar(
            title: Text(content?.meta.englishName ?? 'Surah $_surahNumber'),
            actions: [
              IconButton(
                icon: Icon(
                  _swipeMode ? Icons.view_agenda_outlined : Icons.swipe,
                ),
                tooltip: _swipeMode ? 'Scroll mode' : 'Verse-by-verse mode',
                onPressed: () => setState(() => _swipeMode = !_swipeMode),
              ),
            ],
          ),
          body: Stack(
            children: [
              switch (snapshot.connectionState) {
                ConnectionState.waiting => const Center(
                  child: CircularProgressIndicator(),
                ),
                _ when snapshot.hasError || content == null => _ErrorView(
                  onRetry:
                      () => setState(() {
                        _future = QuranApiService.instance.fetchSurah(
                          _surahNumber,
                        );
                      }),
                ),
                _ =>
                  _swipeMode
                      ? _buildSwipeMode(content)
                      : _buildScrollMode(content),
              },
              Align(
                alignment: Alignment.topCenter,
                child: ConfettiWidget(
                  confettiController: _confetti,
                  blastDirectionality: BlastDirectionality.explosive,
                  numberOfParticles: 70,
                  maxBlastForce: 34,
                  minBlastForce: 14,
                  emissionFrequency: 0.06,
                  gravity: 0.25,
                  colors: const [
                    AppTheme.gold,
                    AppTheme.softGold,
                    AppTheme.emerald,
                    AppTheme.deepGreen,
                    Colors.white,
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildScrollMode(SurahContent content) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: content.verses.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            children: [
              _SurahHeader(meta: content.meta),
              if (_showsBismillah) _buildBismillahLine(),
            ],
          );
        }
        final verse = content.verses[index - 1];
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _onVerseSeen(content, verse);
        });
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _buildVerseCard(content, verse),
        );
      },
    );
  }

  Widget _buildSwipeMode(SurahContent content) {
    final lastPage = content.verses.length - 1;
    final page = _currentPage.clamp(0, lastPage);
    _pageController ??= PageController(initialPage: page);
    // Previous/Next cross surah boundaries; they only disappear at the
    // absolute ends of the Quran (Al-Fatihah 1:1 and An-Nas 114:6).
    final isQuranStart = _surahNumber == 1 && page == 0;
    final isQuranEnd = _surahNumber == _lastSurah && page == lastPage;

    // Count the initially shown verse.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onVerseSeen(content, content.verses[page]);
    });

    // Reaching the very last verse of the Quran: celebrate, stay put.
    if (isQuranEnd && !_quranEndCelebrated) {
      _quranEndCelebrated = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _confetti.play());
    }

    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: content.verses.length,
            onPageChanged: (newPage) {
              setState(() => _currentPage = newPage);
              _onVerseSeen(content, content.verses[newPage]);
            },
            itemBuilder: (context, index) {
              final verse = content.verses[index];
              return SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _SurahHeader(meta: content.meta),
                    if (verse.numberInSurah == 1 && _showsBismillah)
                      _buildBismillahLine(),
                    _buildVerseCard(content, verse),
                  ],
                ),
              );
            },
          ),
        ),
        Material(
          color: Colors.white,
          elevation: 8,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(
                children: [
                  if (!isQuranStart)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed:
                            _celebrating
                                ? null
                                : () =>
                                    page > 0
                                        ? _goToPage(page - 1)
                                        : _goToSurah(
                                          _surahNumber - 1,
                                          page: 1 << 20,
                                        ),
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('Previous'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.deepGreen,
                          side: const BorderSide(color: AppTheme.emerald),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                  if (!isQuranStart && !isQuranEnd) const SizedBox(width: 12),
                  if (!isQuranEnd)
                    Expanded(
                      child: FilledButton.icon(
                        onPressed:
                            _celebrating
                                ? null
                                : () =>
                                    page < lastPage
                                        ? _goToPage(page + 1)
                                        : _finishSurahAndAdvance(),
                        icon: const Icon(Icons.arrow_forward),
                        label: const Text('Next'),
                        iconAlignment: IconAlignment.end,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            '${page + 1} / ${content.meta.verseCount}',
            style: TextStyle(
              fontSize: 13,
              color: Colors.black.withValues(alpha: 0.45),
            ),
          ),
        ),
      ],
    );
  }

  void _goToPage(int page) {
    _pageController?.jumpToPage(page);
  }

  /// Switches verse-by-verse mode to another surah. [page] is clamped to
  /// the new surah's verse range, so a huge value means "last verse".
  void _goToSurah(int surah, {required int page}) {
    setState(() {
      _surahNumber = surah;
      _future = QuranApiService.instance.fetchSurah(surah);
      _pageController?.dispose();
      _pageController = null;
      _currentPage = page;
      _readThisSession.clear();
    });
    _loadState();
  }

  /// Confetti celebration for finishing a surah, then on to the next one.
  void _finishSurahAndAdvance() {
    setState(() => _celebrating = true);
    _confetti.play();
    Timer(const Duration(milliseconds: 1800), () {
      if (!mounted) return;
      _celebrating = false;
      _goToSurah(_surahNumber + 1, page: 0);
    });
  }

  Widget _buildVerseCard(SurahContent content, QuranVerse verse) {
    final playing = _playingVerse == verse.numberInSurah;
    final bookmarked = _bookmarked.contains(verse.numberInSurah);
    final favorited = _favorited.contains(verse.numberInSurah);
    final hasanat = QuranProgressService.hasanatForText(verse.arabic);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppTheme.deepGreen,
                  ),
                  child: Text(
                    '${verse.numberInSurah}',
                    style: const TextStyle(
                      color: AppTheme.ivory,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  AppStrings.quranHasanatNote(hasanat),
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.gold,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _displayArabic(verse),
              textAlign: TextAlign.right,
              textDirection: TextDirection.rtl,
              style: const TextStyle(
                fontSize: 24,
                height: 1.9,
                color: AppTheme.deepGreen,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (verse.transliteration.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                verse.transliteration,
                style: TextStyle(
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                  height: 1.5,
                  color: Colors.black.withValues(alpha: 0.5),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              verse.translation,
              style: const TextStyle(fontSize: 15, height: 1.5),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                IconButton(
                  icon: Icon(
                    playing
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_outline,
                    color: AppTheme.emerald,
                  ),
                  tooltip: 'Play recitation',
                  onPressed: () => _toggleAudio(verse),
                ),
                IconButton(
                  icon: Icon(
                    bookmarked ? Icons.bookmark : Icons.bookmark_border,
                    color: bookmarked ? AppTheme.gold : AppTheme.emerald,
                  ),
                  tooltip: 'Bookmark',
                  onPressed: () => _toggleBookmark(content, verse),
                ),
                IconButton(
                  icon: Icon(
                    favorited ? Icons.favorite : Icons.favorite_border,
                    color: favorited ? AppTheme.gold : AppTheme.emerald,
                  ),
                  tooltip: 'Favorite',
                  onPressed: () => _toggleFavorite(content, verse),
                ),
                const Spacer(),
              ],
            ),
            _TafsirSection(surah: _surahNumber, verse: verse.numberInSurah),
          ],
        ),
      ),
    );
  }
}

class _SurahHeader extends StatelessWidget {
  final SurahMeta meta;

  const _SurahHeader({required this.meta});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.deepGreen, AppTheme.emerald],
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          Text(
            meta.arabicName,
            style: const TextStyle(
              color: AppTheme.ivory,
              fontSize: 26,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${meta.englishName} \u2022 ${meta.englishTranslation}',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppTheme.ivory.withValues(alpha: 0.85),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${meta.verseCount} verses \u2022 ${meta.revelationType}',
            style: TextStyle(
              color: AppTheme.ivory.withValues(alpha: 0.6),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

/// Expandable per-verse tafsir loaded lazily from local assets with a
/// cached network fallback.
class _TafsirSection extends StatefulWidget {
  final int surah;
  final int verse;

  const _TafsirSection({required this.surah, required this.verse});

  @override
  State<_TafsirSection> createState() => _TafsirSectionState();
}

class _TafsirSectionState extends State<_TafsirSection> {
  bool _expanded = false;
  Future<String?>? _future;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            setState(() {
              _expanded = !_expanded;
              _future ??= TafsirService.instance.getTafsir(
                widget.surah,
                widget.verse,
              );
            });
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                const Icon(
                  Icons.menu_book_outlined,
                  size: 18,
                  color: AppTheme.gold,
                ),
                const SizedBox(width: 8),
                const Text(
                  AppStrings.quranTafsir,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.deepGreen,
                  ),
                ),
                const Spacer(),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                  color: AppTheme.emerald,
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          FutureBuilder<String?>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
              }
              final text = snapshot.data;
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.ivory,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    text ?? AppStrings.quranTafsirUnavailable,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color:
                          text == null
                              ? Colors.black.withValues(alpha: 0.5)
                              : Colors.black.withValues(alpha: 0.75),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  final VoidCallback onRetry;

  const _ErrorView({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.wifi_off_outlined,
              size: 44,
              color: AppTheme.emerald,
            ),
            const SizedBox(height: 16),
            const Text(
              AppStrings.quranLoadError,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: onRetry,
              child: const Text(AppStrings.quranRetry),
            ),
          ],
        ),
      ),
    );
  }
}
