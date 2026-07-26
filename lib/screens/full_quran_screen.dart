import 'dart:async';

import 'package:confetti/confetti.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../models/quran_models.dart';
import '../services/quran_api_service.dart';
import '../services/quran_progress_service.dart';
import '../utils/app_strings.dart';
import '../utils/app_theme.dart';

/// The entire Quran as one continuous vertical scroll, from Al-Fatihah
/// (1) to An-Nas (114).
///
/// Arabic-only mushaf-style reading: each surah gets a header (Arabic +
/// English name), the Bismillah where applicable (never before At-Tawbah),
/// and its verses as flowing right-to-left text with inline verse markers.
///
/// Text is the Uthmani edition from api.alquran.cloud (already cached on
/// disk by QuranApiService) — never typed or generated locally. Even the
/// Bismillah line is taken verbatim from the API (Al-Fatihah, verse 1).
///
/// Rendering stays smooth by flattening the whole Quran into a lazy list:
/// one header item per surah plus its verses grouped into small text
/// chunks, so only what is on screen is built. Surah content is fetched
/// on demand as the user scrolls into it.
///
/// The topmost visible surah/verse is tracked while scrolling, shown in
/// the app bar, and saved so reopening the screen resumes at the same
/// spot. A surah selector in the app bar jumps directly to any surah.
class FullQuranScreen extends StatefulWidget {
  const FullQuranScreen({super.key});

  @override
  State<FullQuranScreen> createState() => _FullQuranScreenState();
}

/// One entry in the flattened scroll list.
class _QuranItem {
  final int surah;
  final bool isHeader;

  /// For verse chunks: index of the first verse (0-based) in the surah.
  final int chunkStart;

  const _QuranItem.header(this.surah) : isHeader = true, chunkStart = 0;

  const _QuranItem.chunk(this.surah, this.chunkStart) : isHeader = false;
}

class _FullQuranScreenState extends State<FullQuranScreen> {
  /// Verses per rendered paragraph block. Small enough that each list item
  /// lays out quickly, large enough to read as continuous text.
  static const int _chunkSize = 15;

  static const int _atTawbah = 9;

  Future<void>? _initFuture;
  List<SurahMeta>? _metas;
  List<_QuranItem>? _items;

  /// List index of each surah's header, for direct jumps.
  final Map<int, int> _headerIndex = {};

  final Map<int, SurahContent> _loaded = {};
  final Set<int> _loading = {};
  final Set<int> _failed = {};

  /// Exact Uthmani Bismillah, sourced from the API (Al-Fatihah verse 1).
  String? _bismillah;

  final ItemScrollController _scrollController = ItemScrollController();
  final ItemPositionsListener _positionsListener =
      ItemPositionsListener.create();

  int _initialIndex = 0;
  int _currentSurah = 1;
  int _currentVerse = 1;
  Timer? _saveDebounce;

  /// One long-press recognizer per verse ("surah:verse"), reused across
  /// rebuilds and disposed with the screen.
  final Map<String, LongPressGestureRecognizer> _verseRecognizers = {};

  @override
  void initState() {
    super.initState();
    _initFuture = _init();
    _positionsListener.itemPositions.addListener(_onPositionsChanged);
    // Al-Fatihah provides the Bismillah string and is the top of the scroll.
    _ensureSurahLoaded(1);
  }

  @override
  void dispose() {
    _positionsListener.itemPositions.removeListener(_onPositionsChanged);
    for (final recognizer in _verseRecognizers.values) {
      recognizer.dispose();
    }
    _saveDebounce?.cancel();
    QuranProgressService.instance.setFullQuranPosition(
      _currentSurah,
      _currentVerse,
    );
    super.dispose();
  }

  Future<void> _init() async {
    final metas = await QuranApiService.instance.fetchSurahList();
    _metas = metas;
    _items = _buildItems(metas);

    final saved = await QuranProgressService.instance.getFullQuranPosition();
    if (saved != null) {
      _currentSurah = saved.$1.clamp(1, 114);
      _currentVerse = saved.$2;
      _initialIndex = _indexFor(_currentSurah, _currentVerse);
    }
  }

  List<_QuranItem> _buildItems(List<SurahMeta> metas) {
    final items = <_QuranItem>[];
    _headerIndex.clear();
    for (final meta in metas) {
      _headerIndex[meta.number] = items.length;
      items.add(_QuranItem.header(meta.number));
      for (var start = 0; start < meta.verseCount; start += _chunkSize) {
        items.add(_QuranItem.chunk(meta.number, start));
      }
    }
    return items;
  }

  int _indexFor(int surah, int verse) {
    final header = _headerIndex[surah];
    if (header == null) return 0;
    if (verse <= 1) return header;
    return header + 1 + (verse - 1) ~/ _chunkSize;
  }

  // ------------------------------------------------------ Position tracking

  void _onPositionsChanged() {
    final items = _items;
    if (items == null) return;
    final positions = _positionsListener.itemPositions.value;
    if (positions.isEmpty) return;

    // Topmost item still visible on screen.
    ItemPosition? top;
    for (final p in positions) {
      if (p.itemTrailingEdge <= 0) continue;
      if (top == null || p.index < top.index) top = p;
    }
    if (top == null || top.index >= items.length) return;

    final item = items[top.index];
    final verse = item.isHeader ? 1 : item.chunkStart + 1;
    if (item.surah == _currentSurah && verse == _currentVerse) return;

    setState(() {
      _currentSurah = item.surah;
      _currentVerse = verse;
    });
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 1), () {
      QuranProgressService.instance.setFullQuranPosition(
        _currentSurah,
        _currentVerse,
      );
    });
  }

  // -------------------------------------------------------- Surah selector

  void _openSurahSelector() {
    final metas = _metas;
    if (metas == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.ivory,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder:
          (sheetContext) => DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.75,
            minChildSize: 0.4,
            maxChildSize: 0.95,
            builder:
                (context, scrollController) => Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                      child: Text(
                        AppStrings.quranJumpToSurah,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.deepGreen,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        controller: scrollController,
                        itemCount: metas.length,
                        itemBuilder: (context, index) {
                          final meta = metas[index];
                          final isCurrent = meta.number == _currentSurah;
                          return ListTile(
                            dense: true,
                            selected: isCurrent,
                            selectedTileColor: AppTheme.emerald.withValues(
                              alpha: 0.12,
                            ),
                            leading: CircleAvatar(
                              radius: 16,
                              backgroundColor:
                                  isCurrent
                                      ? AppTheme.emerald
                                      : AppTheme.deepGreen,
                              child: Text(
                                '${meta.number}',
                                style: const TextStyle(
                                  color: AppTheme.ivory,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            title: Text(
                              meta.englishName,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              '${meta.englishTranslation} \u2022 ${meta.verseCount} verses',
                              style: const TextStyle(fontSize: 12),
                            ),
                            trailing: Text(
                              meta.arabicName,
                              textDirection: TextDirection.rtl,
                              style: const TextStyle(
                                fontSize: 18,
                                color: AppTheme.deepGreen,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            onTap: () {
                              Navigator.of(sheetContext).pop();
                              _jumpToSurah(meta.number);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
          ),
    );
  }

  void _jumpToSurah(int surah) {
    final index = _headerIndex[surah];
    if (index == null || !_scrollController.isAttached) return;
    _scrollController.jumpTo(index: index);
    setState(() {
      _currentSurah = surah;
      _currentVerse = 1;
    });
    QuranProgressService.instance.setFullQuranPosition(surah, 1);
  }

  // ----------------------------------------------------------- Verse popup

  /// Hold a verse for 1.5 seconds to open the verse-by-verse popup.
  LongPressGestureRecognizer _recognizerFor(
    SurahContent content,
    QuranVerse verse,
  ) {
    final key = '${content.meta.number}:${verse.numberInSurah}';
    return _verseRecognizers.putIfAbsent(
      key,
      () => LongPressGestureRecognizer(
        duration: const Duration(milliseconds: 1500),
      )..onLongPress = () => _showVersePopup(content, verse.numberInSurah),
    );
  }

  void _showVersePopup(SurahContent content, int verseNumber) {
    showDialog<void>(
      context: context,
      builder: (_) => _VersePopup(content: content, initialVerse: verseNumber),
    );
  }

  // ---------------------------------------------------------- Data loading

  Future<void> _ensureSurahLoaded(int surah) async {
    if (_loaded.containsKey(surah) || _loading.contains(surah)) return;
    _loading.add(surah);
    try {
      final content = await QuranApiService.instance.fetchSurah(surah);
      if (!mounted) return;
      setState(() {
        _loaded[surah] = content;
        _failed.remove(surah);
        if (surah == 1 && content.verses.isNotEmpty) {
          _bismillah = content.verses.first.arabic.trim();
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed.add(surah));
    } finally {
      _loading.remove(surah);
    }
  }

  static const String _arabicDigits =
      '\u0660\u0661\u0662\u0663\u0664\u0665\u0666\u0667\u0668\u0669';

  String _arabicNumber(int n) =>
      n.toString().split('').map((d) => _arabicDigits[int.parse(d)]).join();

  /// The API embeds the Bismillah at the start of verse 1 for every surah
  /// except Al-Fatihah (where it IS verse 1) and At-Tawbah. Since we render
  /// it as its own centered line, strip that exact prefix from the verse.
  String _verseText(int surah, QuranVerse verse) {
    var text = verse.arabic;
    if (verse.numberInSurah == 1 && surah != 1 && surah != _atTawbah) {
      final bismillah = _bismillah;
      if (bismillah != null && text.startsWith(bismillah)) {
        text = text.substring(bismillah.length).trimLeft();
      }
    }
    return text;
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final metas = _metas;
    final currentName =
        metas != null && _currentSurah <= metas.length
            ? metas[_currentSurah - 1].englishName
            : '';
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(AppStrings.quranFullTitle),
            if (currentName.isNotEmpty)
              Text(
                '$currentName \u2022 Verse $_currentVerse',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: AppTheme.ivory.withValues(alpha: 0.85),
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.format_list_numbered),
            tooltip: AppStrings.quranJumpToSurah,
            onPressed: _openSurahSelector,
          ),
        ],
      ),
      body: FutureBuilder<void>(
        future: _initFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = _items;
          if (snapshot.hasError || items == null || metas == null) {
            return _LoadErrorView(
              onRetry:
                  () => setState(() {
                    _initFuture = _init();
                  }),
            );
          }
          return ScrollablePositionedList.builder(
            itemScrollController: _scrollController,
            itemPositionsListener: _positionsListener,
            initialScrollIndex: _initialIndex,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              return item.isHeader
                  ? _buildHeader(metas[item.surah - 1])
                  : _buildChunk(item);
            },
          );
        },
      ),
    );
  }

  Widget _buildHeader(SurahMeta meta) {
    final showBismillah = meta.number != 1 && meta.number != _atTawbah;
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 10),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppTheme.deepGreen, AppTheme.emerald],
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Text(
                  meta.arabicName,
                  textDirection: TextDirection.rtl,
                  style: const TextStyle(
                    color: AppTheme.ivory,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${meta.number}. ${meta.englishName} \u2022 ${meta.englishTranslation}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppTheme.ivory.withValues(alpha: 0.85),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          if (showBismillah && _bismillah != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
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
            ),
        ],
      ),
    );
  }

  Widget _buildChunk(_QuranItem item) {
    final content = _loaded[item.surah];
    if (content == null) {
      if (_failed.contains(item.surah)) {
        // One retry tile per surah; only show it on the first chunk.
        if (item.chunkStart > 0) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            children: [
              const Text(
                AppStrings.quranLoadError,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () {
                  setState(() => _failed.remove(item.surah));
                  _ensureSurahLoaded(item.surah);
                },
                child: const Text(AppStrings.quranRetry),
              ),
            ],
          ),
        );
      }
      _ensureSurahLoaded(item.surah);
      // Lightweight placeholder keeps scrolling responsive while loading.
      if (item.chunkStart > 0) return const SizedBox(height: 120);
      return const SizedBox(
        height: 120,
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    }

    final verses = content.verses;
    final end = (item.chunkStart + _chunkSize).clamp(0, verses.length);
    final chunk = verses.sublist(item.chunkStart, end);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Text.rich(
          TextSpan(
            children: [
              for (final verse in chunk) ...[
                TextSpan(
                  text: _verseText(item.surah, verse),
                  recognizer: _recognizerFor(content, verse),
                ),
                TextSpan(
                  text: ' \uFD3F${_arabicNumber(verse.numberInSurah)}\uFD3E ',
                  recognizer: _recognizerFor(content, verse),
                  style: const TextStyle(
                    color: AppTheme.gold,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
          textAlign: TextAlign.justify,
          style: const TextStyle(
            fontSize: 26,
            height: 2.0,
            color: AppTheme.nightBlue,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// Verse-by-verse popup opened by holding a verse in the continuous
/// scroll. Shows one verse at a time (Arabic, transliteration,
/// translation) with instant Previous/Next navigation, without leaving
/// the Full Quran page.
///
/// Navigation continues across surah boundaries: Next on a surah's last
/// verse plays a confetti celebration and moves to the next surah's
/// first verse; Previous on verse 1 moves to the previous surah's last
/// verse. The buttons only disappear at the absolute ends of the Quran.
class _VersePopup extends StatefulWidget {
  final SurahContent content;
  final int initialVerse;

  const _VersePopup({required this.content, required this.initialVerse});

  @override
  State<_VersePopup> createState() => _VersePopupState();
}

class _VersePopupState extends State<_VersePopup> {
  static const int _lastSurah = 114;

  late SurahContent _content;
  late int _index;
  bool _loading = false;
  bool _celebrating = false;
  bool _quranEndCelebrated = false;
  String? _bismillah;

  final ConfettiController _confetti = ConfettiController(
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void initState() {
    super.initState();
    _content = widget.content;
    _index = (widget.initialVerse - 1).clamp(
      0,
      widget.content.verses.length - 1,
    );
    QuranApiService.instance
        .fetchBismillah()
        .then((bismillah) {
          if (mounted) setState(() => _bismillah = bismillah);
        })
        .catchError((_) {
          // Offline with no cache: verse 1 keeps its embedded Bismillah.
        });
  }

  @override
  void dispose() {
    _confetti.dispose();
    super.dispose();
  }

  /// True when the current verse shows a separate Bismillah line above it
  /// (verse 1 of every surah except Al-Fatihah and At-Tawbah).
  bool get _showsBismillah =>
      _index == 0 &&
      _content.meta.number != 1 &&
      _content.meta.number != 9 &&
      _bismillah != null;

  /// Arabic text with the embedded Bismillah prefix split off verse 1,
  /// since it is rendered as its own centered line.
  String _displayArabic(QuranVerse verse) {
    final bismillah = _bismillah;
    if (_showsBismillah &&
        bismillah != null &&
        verse.arabic.startsWith(bismillah)) {
      final stripped = verse.arabic.substring(bismillah.length).trimLeft();
      if (stripped.isNotEmpty) return stripped;
    }
    return verse.arabic;
  }

  Future<void> _openSurah(int surah, {required bool atEnd}) async {
    setState(() => _loading = true);
    try {
      final content = await QuranApiService.instance.fetchSurah(surah);
      if (!mounted) return;
      setState(() {
        _content = content;
        _index = atEnd ? content.verses.length - 1 : 0;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _previous() {
    if (_index > 0) {
      setState(() => _index -= 1);
    } else {
      _openSurah(_content.meta.number - 1, atEnd: true);
    }
  }

  void _next() {
    if (_index < _content.verses.length - 1) {
      setState(() => _index += 1);
      return;
    }
    // Finished the surah: celebrate, then move to the next one.
    setState(() => _celebrating = true);
    _confetti.play();
    Timer(const Duration(milliseconds: 1800), () {
      if (!mounted) return;
      setState(() => _celebrating = false);
      _openSurah(_content.meta.number + 1, atEnd: false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final meta = _content.meta;
    final verse = _content.verses[_index];
    final isQuranStart = meta.number == 1 && _index == 0;
    final isQuranEnd =
        meta.number == _lastSurah && _index == _content.verses.length - 1;

    // Reaching the very last verse of the Quran: celebrate, stay put.
    if (isQuranEnd && !_quranEndCelebrated) {
      _quranEndCelebrated = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _confetti.play());
    }

    return Dialog(
      backgroundColor: AppTheme.ivory,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AppTheme.deepGreen, AppTheme.emerald],
                  ),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            meta.englishName,
                            style: const TextStyle(
                              color: AppTheme.ivory,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            'Verse ${verse.numberInSurah} of ${meta.verseCount}',
                            style: TextStyle(
                              color: AppTheme.ivory.withValues(alpha: 0.8),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: AppTheme.ivory),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_showsBismillah) ...[
                        Text(
                          _bismillah!,
                          textAlign: TextAlign.center,
                          textDirection: TextDirection.rtl,
                          style: const TextStyle(
                            fontSize: 22,
                            height: 1.8,
                            color: AppTheme.deepGreen,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
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
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                child: Row(
                  children: [
                    if (!isQuranStart)
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed:
                              _celebrating || _loading ? null : _previous,
                          icon: const Icon(Icons.arrow_back),
                          label: const Text('Previous'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.deepGreen,
                            side: const BorderSide(color: AppTheme.emerald),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    if (!isQuranStart && !isQuranEnd) const SizedBox(width: 12),
                    if (!isQuranEnd)
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _celebrating || _loading ? null : _next,
                          icon: const Icon(Icons.arrow_forward),
                          label: const Text('Next'),
                          iconAlignment: IconAlignment.end,
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          ConfettiWidget(
            confettiController: _confetti,
            blastDirectionality: BlastDirectionality.explosive,
            numberOfParticles: 60,
            maxBlastForce: 32,
            minBlastForce: 12,
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
        ],
      ),
    );
  }
}

class _LoadErrorView extends StatelessWidget {
  final VoidCallback onRetry;

  const _LoadErrorView({required this.onRetry});

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
