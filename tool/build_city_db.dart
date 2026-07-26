// Builds the compact offline city database asset from GeoNames dumps.
//
// Inputs (download from https://download.geonames.org/export/dump/):
//   tool/geodata/cities1000.txt      - all cities with population > 1000
//   tool/geodata/admin1CodesASCII.txt - admin region names (e.g. US.IL -> Illinois)
//   tool/geodata/countryInfo.txt     - ISO country code -> country name
//
// Output:
//   assets/geonames/cities.tsv.gz
//
// Output line format (tab separated):
//   name \t altNames(|-separated) \t country \t admin1 \t lat \t lng \t tz \t population
//
// Run with: dart run tool/build_city_db.dart
//
// GeoNames data is licensed under CC BY 4.0 (https://www.geonames.org/).

import 'dart:convert';
import 'dart:io';

void main() {
  final root = Directory.current.path;
  final citiesFile = File('$root/tool/geodata/cities1000.txt');
  final admin1File = File('$root/tool/geodata/admin1CodesASCII.txt');
  final countryFile = File('$root/tool/geodata/countryInfo.txt');

  if (!citiesFile.existsSync()) {
    stderr.writeln(
      'Missing ${citiesFile.path}. Download cities1000.zip from '
      'https://download.geonames.org/export/dump/ and unzip it there.',
    );
    exit(1);
  }

  // --- admin1 codes: "US.IL\tIllinois\tIllinois\t4896861"
  final admin1 = <String, String>{};
  for (final line in admin1File.readAsLinesSync()) {
    final parts = line.split('\t');
    if (parts.length >= 2) admin1[parts[0]] = parts[1];
  }

  // --- country info: code is col 0, name is col 4. Comment lines start with #.
  final countries = <String, String>{};
  for (final line in countryFile.readAsLinesSync()) {
    if (line.startsWith('#')) continue;
    final parts = line.split('\t');
    if (parts.length >= 5) countries[parts[0]] = parts[4];
  }

  final asciiOnly = RegExp(r"^[A-Za-z][A-Za-z .'\-]{2,39}$");
  final buffer = StringBuffer();
  var count = 0;

  for (final line in citiesFile.readAsLinesSync()) {
    final f = line.split('\t');
    if (f.length < 19) continue;

    final name = f[1];
    final asciiName = f[2];
    final altRaw = f[3];
    final lat = double.tryParse(f[4]);
    final lng = double.tryParse(f[5]);
    final countryCode = f[8];
    final admin1Code = f[10];
    final population = int.tryParse(f[14]) ?? 0;
    final timezone = f[17];

    if (lat == null || lng == null || name.isEmpty) continue;

    final country = countries[countryCode] ?? countryCode;
    final region = admin1['$countryCode.$admin1Code'] ?? '';

    // Alternate names: keep a few ASCII alternates for findability without
    // exploding the asset size. ASCII name is always kept if it differs.
    final alts = <String>{};
    if (asciiName.isNotEmpty && asciiName.toLowerCase() != name.toLowerCase()) {
      alts.add(asciiName);
    }
    if (population >= 10000 && altRaw.isNotEmpty) {
      for (final alt in altRaw.split(',')) {
        if (alts.length >= 4) break;
        final trimmed = alt.trim();
        if (trimmed.toLowerCase() == name.toLowerCase()) continue;
        if (alts.any((a) => a.toLowerCase() == trimmed.toLowerCase())) continue;
        if (asciiOnly.hasMatch(trimmed)) alts.add(trimmed);
      }
    }

    buffer
      ..write(name)
      ..write('\t')
      ..write(alts.join('|'))
      ..write('\t')
      ..write(country)
      ..write('\t')
      ..write(region)
      ..write('\t')
      ..write(lat.toStringAsFixed(4))
      ..write('\t')
      ..write(lng.toStringAsFixed(4))
      ..write('\t')
      ..write(timezone)
      ..write('\t')
      ..write(population)
      ..write('\n');
    count++;
  }

  final outDir = Directory('$root/assets/geonames')
    ..createSync(recursive: true);
  final raw = utf8.encode(buffer.toString());
  final compressed = gzip.encode(raw);
  final outFile = File('${outDir.path}/cities.tsv.gz')
    ..writeAsBytesSync(compressed);

  stdout.writeln('Wrote $count cities.');
  stdout.writeln(
    'Raw size: ${(raw.length / 1024 / 1024).toStringAsFixed(1)} MB',
  );
  stdout.writeln(
    'Compressed: ${(compressed.length / 1024 / 1024).toStringAsFixed(1)} MB -> ${outFile.path}',
  );
}
