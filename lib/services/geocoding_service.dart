import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/city.dart';
import 'timezone_service.dart';

/// Online fallback when the offline city search finds nothing.
///
/// Uses the platform geocoder (Google Play services on Android, Apple on
/// iOS) rather than public Nominatim/OSM endpoints, so there are no
/// attribution or rate-limit concerns beyond the platform's own. Lookups
/// only run on explicit user action and successful results are cached
/// locally so repeat searches stay offline.
class GeocodingService {
  static const _cacheKey = 'geocode_cache_v1';
  static const _maxCacheEntries = 50;

  final SharedPreferences prefs;
  final TimezoneService timezoneService;

  GeocodingService({required this.prefs, required this.timezoneService});

  /// Geocodes a free-form place query. Returns cached results when available.
  Future<List<City>> lookup(String query) async {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return const [];

    final cache = _readCache();
    final cached = cache[normalized];
    if (cached != null) {
      return [
        for (final item in cached) City.fromJson(item as Map<String, dynamic>),
      ];
    }

    List<geo.Location> locations;
    try {
      locations = await geo.locationFromAddress(query.trim());
    } catch (e) {
      debugPrint('Online geocoding failed: $e');
      return const [];
    }

    final results = <City>[];
    for (final location in locations.take(5)) {
      String name = query.trim();
      String country = '';
      String region = '';
      try {
        final placemarks = await geo.placemarkFromCoordinates(
          location.latitude,
          location.longitude,
        );
        if (placemarks.isNotEmpty) {
          final p = placemarks.first;
          name =
              p.locality?.isNotEmpty == true
                  ? p.locality!
                  : (p.subAdministrativeArea?.isNotEmpty == true
                      ? p.subAdministrativeArea!
                      : name);
          region = p.administrativeArea ?? '';
          country = p.country ?? '';
        }
      } catch (e) {
        debugPrint('Reverse geocoding for label failed: $e');
      }

      results.add(
        City(
          name: name,
          alternateNames: const [],
          country: country,
          region: region,
          latitude: location.latitude,
          longitude: location.longitude,
          timezone: timezoneService.timezoneForCoordinates(
            location.latitude,
            location.longitude,
          ),
          population: 0,
        ),
      );
    }

    if (results.isNotEmpty) {
      cache[normalized] = [for (final c in results) c.toJson()];
      _writeCache(cache);
    }
    return results;
  }

  Map<String, dynamic> _readCache() {
    final raw = prefs.getString(_cacheKey);
    if (raw == null) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  void _writeCache(Map<String, dynamic> cache) {
    // Evict oldest entries beyond the cap (insertion order preserved).
    while (cache.length > _maxCacheEntries) {
      cache.remove(cache.keys.first);
    }
    prefs.setString(_cacheKey, jsonEncode(cache));
  }
}
