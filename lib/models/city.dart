/// A place from the offline GeoNames database (or an online geocoding result).
///
/// Cities only provide coordinates + timezone. Prayer times are always
/// calculated from latitude/longitude, never from the city name.
class City {
  final String name;
  final List<String> alternateNames;
  final String country;

  /// Admin region / state, e.g. "Illinois". May be empty.
  final String region;
  final double latitude;
  final double longitude;

  /// IANA timezone from GeoNames, e.g. "America/Detroit". May be empty;
  /// resolve from coordinates in that case.
  final String timezone;
  final int population;

  const City({
    required this.name,
    required this.alternateNames,
    required this.country,
    required this.region,
    required this.latitude,
    required this.longitude,
    required this.timezone,
    required this.population,
  });

  /// Disambiguated label, e.g. "Springfield, Illinois, United States".
  String get label =>
      region.isNotEmpty ? '$name, $region, $country' : '$name, $country';

  /// Short label without country, e.g. "Springfield, Illinois".
  String get shortLabel => region.isNotEmpty ? '$name, $region' : name;

  Map<String, dynamic> toJson() => {
        'name': name,
        'alternateNames': alternateNames,
        'country': country,
        'region': region,
        'latitude': latitude,
        'longitude': longitude,
        'timezone': timezone,
        'population': population,
      };

  factory City.fromJson(Map<String, dynamic> json) => City(
        name: json['name'] as String,
        alternateNames: (json['alternateNames'] as List<dynamic>? ?? const [])
            .cast<String>(),
        country: json['country'] as String? ?? '',
        region: json['region'] as String? ?? '',
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        timezone: json['timezone'] as String? ?? '',
        population: json['population'] as int? ?? 0,
      );
}
