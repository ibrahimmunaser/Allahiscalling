import 'package:geolocator/geolocator.dart';

/// Outcome of a device location request.
enum LocationResultStatus {
  success,
  serviceDisabled,
  permissionDenied,
  permissionDeniedForever,
  error,
}

class LocationResult {
  final LocationResultStatus status;
  final double? latitude;
  final double? longitude;

  const LocationResult(this.status, {this.latitude, this.longitude});

  bool get isSuccess => status == LocationResultStatus.success;
}

/// Wraps geolocator: permission flow + current coordinates.
/// Manual fallback (city list / raw coordinates) lives in the UI and is
/// stored through settings; this service only handles the device GPS path.
///
/// Two entry points with a deliberate distinction:
/// - [getCurrentLocation] may show the OS permission prompt. Call it ONLY
///   from explicit user actions ("Use current location" buttons).
/// - [getCurrentLocationIfPermitted] never prompts. Use it from lifecycle
///   paths (app launch/resume) so a user who denied permission is never
///   nagged automatically.
class LocationService {
  // Injectable for tests; default to the real geolocator calls.
  final Future<bool> Function() _isServiceEnabled;
  final Future<LocationPermission> Function() _checkPermission;
  final Future<LocationPermission> Function() _requestPermission;
  final Future<Position> Function() _getPosition;
  final Future<Position?> Function() _getLastKnown;

  LocationService({
    Future<bool> Function()? isServiceEnabled,
    Future<LocationPermission> Function()? checkPermission,
    Future<LocationPermission> Function()? requestPermission,
    Future<Position> Function()? getPosition,
    Future<Position?> Function()? getLastKnown,
  })  : _isServiceEnabled =
            isServiceEnabled ?? Geolocator.isLocationServiceEnabled,
        _checkPermission = checkPermission ?? Geolocator.checkPermission,
        _requestPermission =
            requestPermission ?? Geolocator.requestPermission,
        _getPosition = getPosition ?? _defaultGetPosition,
        _getLastKnown = getLastKnown ?? Geolocator.getLastKnownPosition;

  static Future<Position> _defaultGetPosition() =>
      Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low, // city-level is enough for salah
          timeLimit: Duration(seconds: 20),
        ),
      );

  /// Requests permission (if needed) and returns current coordinates.
  /// May show the OS permission prompt — explicit user action only.
  Future<LocationResult> getCurrentLocation() =>
      _locate(mayPrompt: true);

  /// Returns current coordinates only when permission is already granted.
  /// Never shows a permission prompt; denied states return silently. Safe
  /// for lifecycle triggers (launch, resume).
  Future<LocationResult> getCurrentLocationIfPermitted() =>
      _locate(mayPrompt: false);

  Future<LocationResult> _locate({required bool mayPrompt}) async {
    try {
      if (!await _isServiceEnabled()) {
        return const LocationResult(LocationResultStatus.serviceDisabled);
      }

      var permission = await _checkPermission();
      if (permission == LocationPermission.denied && mayPrompt) {
        permission = await _requestPermission();
      }
      if (permission == LocationPermission.denied) {
        return const LocationResult(LocationResultStatus.permissionDenied);
      }
      if (permission == LocationPermission.deniedForever) {
        return const LocationResult(
            LocationResultStatus.permissionDeniedForever);
      }

      final position = await _getPosition();
      return LocationResult(
        LocationResultStatus.success,
        latitude: position.latitude,
        longitude: position.longitude,
      );
    } catch (_) {
      // Time out or platform error: try last known position as a fallback.
      try {
        final last = await _getLastKnown();
        if (last != null) {
          return LocationResult(
            LocationResultStatus.success,
            latitude: last.latitude,
            longitude: last.longitude,
          );
        }
      } catch (_) {}
      return const LocationResult(LocationResultStatus.error);
    }
  }

  Future<LocationPermission> checkPermission() => _checkPermission();

  /// Opens OS app settings so the user can grant a permanently-denied
  /// permission.
  Future<bool> openAppSettings() => Geolocator.openAppSettings();

  Future<bool> openLocationSettings() => Geolocator.openLocationSettings();
}
