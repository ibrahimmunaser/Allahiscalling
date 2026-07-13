import 'package:allah_invites_you_to_salah/services/city_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final db = CityDatabase.instance;

  setUpAll(() async {
    await db.ensureLoaded();
  });

  test('loads the offline database', () {
    expect(db.isLoaded, isTrue);
  });

  test('finds a major city by exact name, ranked above smaller ones', () async {
    final results = await db.search('Detroit');
    expect(results, isNotEmpty);
    expect(results.first.name, 'Detroit');
    expect(results.first.region, 'Michigan');
    expect(results.first.timezone, 'America/Detroit');
  });

  test('duplicate names are disambiguated by region and country', () async {
    final results = await db.search('Springfield');
    final labels = results.map((c) => c.label).toList();
    // Multiple distinct Springfields must be present and tell themselves apart.
    expect(labels.toSet().length, labels.length);
    expect(
      labels.where((l) => l.startsWith('Springfield,')).length,
      greaterThan(2),
    );
  });

  test('region qualifier narrows duplicates', () async {
    final results = await db.search('Springfield, Missouri');
    expect(results, isNotEmpty);
    expect(results.first.region, 'Missouri');
  });

  test('qualifier without comma also works', () async {
    final results = await db.search('springfield illinois');
    expect(results, isNotEmpty);
    expect(results.first.region, 'Illinois');
  });

  test('country shorthand "usa" is understood', () async {
    final results = await db.search('detroit usa');
    expect(results, isNotEmpty);
    expect(results.first.country, 'United States');
  });

  test('diacritics are folded', () async {
    final results = await db.search('sao paulo');
    expect(results, isNotEmpty);
    expect(results.first.name, 'São Paulo');
  });

  test('fuzzy search recovers from typos', () async {
    final results = await db.search('Detriot');
    expect(results.map((c) => c.name), contains('Detroit'));
  });

  test('nearby returns closest city first', () async {
    // Coordinates in downtown Detroit.
    final results = await db.nearby(42.3314, -83.0458, limit: 5);
    expect(results, isNotEmpty);
    expect(results.first.name, 'Detroit');
  });

  test('cities carry coordinates, timezone, and population', () async {
    final results = await db.search('Makkah');
    expect(results, isNotEmpty);
    final makkah = results.first;
    expect(makkah.latitude, closeTo(21.42, 0.2));
    expect(makkah.longitude, closeTo(39.82, 0.2));
    expect(makkah.timezone, 'Asia/Riyadh');
    expect(makkah.population, greaterThan(1000000));
  });
}
