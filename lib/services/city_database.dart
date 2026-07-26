import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/city.dart';

/// Searchable offline city database built from GeoNames (cities with
/// population > 1000, ~170k places worldwide).
///
/// Search supports: city name, alternate names, country, admin region,
/// fuzzy matching, and nearby lookup. Results are ranked by relevance
/// first, population second, so "Springfield, Illinois, United States" and
/// "Springfield, Missouri, United States" both surface clearly.
class CityDatabase {
  static final CityDatabase instance = CityDatabase._();

  CityDatabase._();

  List<_IndexedCity>? _cities;
  Future<void>? _loading;

  bool get isLoaded => _cities != null;

  /// Loads and parses the asset off the UI thread. Safe to call repeatedly.
  Future<void> ensureLoaded() {
    if (_cities != null) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    final data = await rootBundle.load('assets/geonames/cities.tsv.gz');
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    _cities = await compute(_parseCityDatabase, bytes);
    _loading = null;
  }

  /// Ranked search. Returns up to [limit] cities.
  Future<List<City>> search(String query, {int limit = 30}) async {
    await ensureLoaded();
    final q = _fold(query.trim());
    if (q.isEmpty) return const [];

    final cities = _cities!;
    final scored = <(_IndexedCity, double)>[];

    // Split "springfield, illinois" / "springfield usa" into a name part and
    // optional region/country qualifiers.
    final commaParts =
        q.split(',').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
    final namePart = commaParts.isEmpty ? q : commaParts.first;
    final qualifiers = commaParts.skip(1).toList();
    final nameTokens = namePart.split(' ').where((t) => t.isNotEmpty).toList();

    for (final city in cities) {
      double score = _scoreName(city, namePart);

      // No comma: allow trailing tokens to act as region/country qualifiers,
      // e.g. "springfield illinois" or "detroit usa".
      if (score == 0 && qualifiers.isEmpty && nameTokens.length > 1) {
        for (var split = nameTokens.length - 1; split >= 1; split--) {
          final head = nameTokens.sublist(0, split).join(' ');
          final tail = nameTokens.sublist(split);
          final headScore = _scoreName(city, head);
          if (headScore > 0 && tail.every((t) => _matchesPlace(city, t))) {
            score = headScore;
            break;
          }
        }
      }

      if (score == 0) continue;

      if (qualifiers.isNotEmpty &&
          !qualifiers.every(
            (part) => part
                .split(' ')
                .where((t) => t.isNotEmpty)
                .every((t) => _matchesPlace(city, t)),
          )) {
        continue;
      }

      // Population as a tiebreaker so famous cities rank above hamlets.
      score += math.min(math.log(city.city.population + 10) * 8, 120);
      scored.add((city, score));
    }

    // Fuzzy fallback when the query found little (typos like "detriot").
    if (scored.length < 5 && namePart.length >= 4 && qualifiers.isEmpty) {
      final maxDistance = namePart.length >= 7 ? 2 : 1;
      for (final city in cities) {
        if ((city.nameFolded.length - namePart.length).abs() > maxDistance) {
          continue;
        }
        if (city.nameFolded.isEmpty ||
            city.nameFolded.codeUnitAt(0) != namePart.codeUnitAt(0)) {
          continue;
        }
        final distance = _boundedLevenshtein(
          city.nameFolded,
          namePart,
          maxDistance,
        );
        if (distance < 0) continue;
        var score = 300.0 - distance * 80;
        score += math.min(math.log(city.city.population + 10) * 8, 120);
        scored.add((city, score));
      }
    }

    scored.sort((a, b) {
      final byScore = b.$2.compareTo(a.$2);
      if (byScore != 0) return byScore;
      return b.$1.city.population.compareTo(a.$1.city.population);
    });

    final seen = <String>{};
    final results = <City>[];
    for (final (indexed, _) in scored) {
      final key = indexed.city.label.toLowerCase();
      if (!seen.add(key)) continue;
      results.add(indexed.city);
      if (results.length >= limit) break;
    }
    return results;
  }

  /// Cities closest to the given coordinates, nearest first.
  ///
  /// Bounded selection: a single O(n·k) pass keeping only the best [limit]
  /// candidates, instead of materializing and sorting a 170k-entry list.
  /// For the small limits used by the UI this allocates almost nothing.
  Future<List<City>> nearby(
    double latitude,
    double longitude, {
    int limit = 20,
  }) async {
    await ensureLoaded();
    final best = <(City, double)>[];
    var worst = double.infinity;
    for (final c in _cities!) {
      final d = _squaredDistance(latitude, longitude, c.city);
      if (best.length >= limit && d >= worst) continue;
      // Insert in sorted position (list is tiny: <= limit entries).
      var i = best.length;
      while (i > 0 && best[i - 1].$2 > d) {
        i--;
      }
      best.insert(i, (c.city, d));
      if (best.length > limit) best.removeLast();
      worst = best.last.$2;
    }
    return [for (final (city, _) in best) city];
  }

  /// The single closest city, used to label GPS coordinates offline.
  Future<City?> nearest(double latitude, double longitude) async {
    final results = await nearby(latitude, longitude, limit: 1);
    return results.isEmpty ? null : results.first;
  }

  // ---------------------------------------------------------------- scoring

  double _scoreName(_IndexedCity city, String query) {
    final name = city.nameFolded;
    if (name == query) return 1000;
    if (name.startsWith(query)) return 800;
    // Word-boundary prefix: "york" matches "New York".
    if (name.contains(' $query')) return 700;
    for (final alt in city.altFolded) {
      if (alt == query) return 650;
      if (alt.startsWith(query)) return 550;
    }
    if (query.length >= 3 && name.contains(query)) return 400;
    if (query.length >= 4) {
      for (final alt in city.altFolded) {
        if (alt.contains(query)) return 300;
      }
    }
    return 0;
  }

  bool _matchesPlace(_IndexedCity city, String token) {
    if (token.isEmpty) return true;
    bool wordPrefix(String haystack) =>
        haystack.startsWith(token) || haystack.contains(' $token');
    if (wordPrefix(city.countryFolded) || wordPrefix(city.regionFolded)) {
      return true;
    }
    // Common country shorthands live in alternates ("usa" is not in the
    // country name "United States"), so also allow a few manual expansions.
    const countryAliases = {
      'usa': 'united states',
      'us': 'united states',
      'uk': 'united kingdom',
      'uae': 'united arab emirates',
      'ksa': 'saudi arabia',
    };
    final alias = countryAliases[token];
    return alias != null && city.countryFolded == alias;
  }

  static double _squaredDistance(double lat, double lng, City city) {
    final dLat = city.latitude - lat;
    var dLng = (city.longitude - lng).abs();
    if (dLng > 180) dLng = 360 - dLng;
    final scaled = dLng * math.cos(lat * math.pi / 180);
    return dLat * dLat + scaled * scaled;
  }

  /// Levenshtein distance capped at [max]; returns -1 when exceeded.
  static int _boundedLevenshtein(String a, String b, int max) {
    if ((a.length - b.length).abs() > max) return -1;
    var previous = List<int>.generate(b.length + 1, (i) => i);
    final current = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      current[0] = i;
      var rowMin = current[0];
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        current[j] = math.min(
          math.min(current[j - 1] + 1, previous[j] + 1),
          previous[j - 1] + cost,
        );
        rowMin = math.min(rowMin, current[j]);
      }
      if (rowMin > max) return -1;
      previous = List<int>.from(current);
    }
    return previous[b.length] <= max ? previous[b.length] : -1;
  }
}

/// City plus pre-folded strings so search scans stay fast.
class _IndexedCity {
  final City city;
  final String nameFolded;
  final List<String> altFolded;
  final String countryFolded;
  final String regionFolded;

  _IndexedCity(this.city)
    : nameFolded = _fold(city.name),
      altFolded = [for (final a in city.alternateNames) _fold(a)],
      countryFolded = _fold(city.country),
      regionFolded = _fold(city.region);
}

/// Lowercase + strip diacritics so "São Paulo" matches "sao paulo".
String _fold(String input) {
  final lower = input.toLowerCase();
  final buffer = StringBuffer();
  for (final rune in lower.runes) {
    buffer.write(_diacriticMap[rune] ?? String.fromCharCode(rune));
  }
  return buffer.toString();
}

final Map<int, String> _diacriticMap = () {
  const groups = {
    'a': 'àáâãäåāăą',
    'e': 'èéêëēĕėęě',
    'i': 'ìíîïĩīĭįı',
    'o': 'òóôõöøōŏő',
    'u': 'ùúûüũūŭůűų',
    'y': 'ýÿ',
    'c': 'çćĉċč',
    'n': 'ñńņň',
    's': 'śŝşšṣ',
    'z': 'źżž',
    'g': 'ğĝ',
    'd': 'đðḍ',
    'l': 'łļľĺ',
    't': 'ṭþ',
  };
  final map = <int, String>{};
  groups.forEach((plain, accented) {
    for (final rune in accented.runes) {
      map[rune] = plain;
    }
  });
  return map;
}();

/// Runs in a background isolate: gunzip + parse the TSV asset.
List<_IndexedCity> _parseCityDatabase(Uint8List bytes) {
  final text = utf8.decode(gzip.decode(bytes));
  final lines = const LineSplitter().convert(text);
  final result = <_IndexedCity>[];
  for (final line in lines) {
    final f = line.split('\t');
    if (f.length < 8) continue;
    final lat = double.tryParse(f[4]);
    final lng = double.tryParse(f[5]);
    if (lat == null || lng == null) continue;
    result.add(
      _IndexedCity(
        City(
          name: f[0],
          alternateNames: f[1].isEmpty ? const [] : f[1].split('|'),
          country: f[2],
          region: f[3],
          latitude: lat,
          longitude: lng,
          timezone: f[6],
          population: int.tryParse(f[7]) ?? 0,
        ),
      ),
    );
  }
  return result;
}
