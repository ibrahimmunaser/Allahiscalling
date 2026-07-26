import 'package:allah_invites_you_to_salah/services/location_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

Position _position(double lat, double lng) => Position(
  latitude: lat,
  longitude: lng,
  timestamp: DateTime(2026, 7, 4),
  accuracy: 10,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

void main() {
  group('passive path (lifecycle) never prompts', () {
    test('denied: returns silently without requesting permission', () async {
      var promptShown = false;
      final service = LocationService(
        isServiceEnabled: () async => true,
        checkPermission: () async => LocationPermission.denied,
        requestPermission: () async {
          promptShown = true;
          return LocationPermission.whileInUse;
        },
        getPosition: () async => _position(40.7, -74.0),
        getLastKnown: () async => null,
      );

      final result = await service.getCurrentLocationIfPermitted();

      expect(result.status, LocationResultStatus.permissionDenied);
      expect(
        promptShown,
        isFalse,
        reason: 'lifecycle path must never launch a permission prompt',
      );
    });

    test('permanently denied: returns silently without requesting', () async {
      var promptShown = false;
      final service = LocationService(
        isServiceEnabled: () async => true,
        checkPermission: () async => LocationPermission.deniedForever,
        requestPermission: () async {
          promptShown = true;
          return LocationPermission.denied;
        },
        getPosition: () async => _position(40.7, -74.0),
        getLastKnown: () async => null,
      );

      final result = await service.getCurrentLocationIfPermitted();

      expect(result.status, LocationResultStatus.permissionDeniedForever);
      expect(promptShown, isFalse);
    });

    test('granted: refreshes the location without prompting', () async {
      var promptShown = false;
      final service = LocationService(
        isServiceEnabled: () async => true,
        checkPermission: () async => LocationPermission.whileInUse,
        requestPermission: () async {
          promptShown = true;
          return LocationPermission.whileInUse;
        },
        getPosition: () async => _position(40.7128, -74.0060),
        getLastKnown: () async => null,
      );

      final result = await service.getCurrentLocationIfPermitted();

      expect(result.status, LocationResultStatus.success);
      expect(result.latitude, closeTo(40.7128, 1e-9));
      expect(result.longitude, closeTo(-74.0060, 1e-9));
      expect(promptShown, isFalse);
    });
  });

  group('explicit user action path', () {
    test('denied: requests permission once and honors the grant', () async {
      var promptCount = 0;
      final service = LocationService(
        isServiceEnabled: () async => true,
        checkPermission: () async => LocationPermission.denied,
        requestPermission: () async {
          promptCount++;
          return LocationPermission.whileInUse;
        },
        getPosition: () async => _position(42.33, -83.05),
        getLastKnown: () async => null,
      );

      final result = await service.getCurrentLocation();

      expect(result.status, LocationResultStatus.success);
      expect(promptCount, 1);
    });

    test('denied then denied again: reports denial, no crash', () async {
      final service = LocationService(
        isServiceEnabled: () async => true,
        checkPermission: () async => LocationPermission.denied,
        requestPermission: () async => LocationPermission.denied,
        getPosition: () async => _position(0, 0),
        getLastKnown: () async => null,
      );

      final result = await service.getCurrentLocation();
      expect(result.status, LocationResultStatus.permissionDenied);
    });

    test(
      'permanently denied: never re-prompts (OS would suppress anyway)',
      () async {
        var promptShown = false;
        final service = LocationService(
          isServiceEnabled: () async => true,
          checkPermission: () async => LocationPermission.deniedForever,
          requestPermission: () async {
            promptShown = true;
            return LocationPermission.deniedForever;
          },
          getPosition: () async => _position(0, 0),
          getLastKnown: () async => null,
        );

        final result = await service.getCurrentLocation();
        expect(result.status, LocationResultStatus.permissionDeniedForever);
        expect(promptShown, isFalse);
      },
    );
  });

  group('failure fallbacks', () {
    test('services disabled reported distinctly', () async {
      final service = LocationService(
        isServiceEnabled: () async => false,
        checkPermission: () async => LocationPermission.whileInUse,
        requestPermission: () async => LocationPermission.whileInUse,
        getPosition: () async => _position(0, 0),
        getLastKnown: () async => null,
      );
      final result = await service.getCurrentLocationIfPermitted();
      expect(result.status, LocationResultStatus.serviceDisabled);
    });

    test('position timeout falls back to last known position', () async {
      final service = LocationService(
        isServiceEnabled: () async => true,
        checkPermission: () async => LocationPermission.always,
        requestPermission: () async => LocationPermission.always,
        getPosition: () async => throw Exception('timeout'),
        getLastKnown: () async => _position(51.5, -0.12),
      );
      final result = await service.getCurrentLocationIfPermitted();
      expect(result.status, LocationResultStatus.success);
      expect(result.latitude, closeTo(51.5, 1e-9));
    });

    test('total failure reports error', () async {
      final service = LocationService(
        isServiceEnabled: () async => true,
        checkPermission: () async => LocationPermission.always,
        requestPermission: () async => LocationPermission.always,
        getPosition: () async => throw Exception('timeout'),
        getLastKnown: () async => null,
      );
      final result = await service.getCurrentLocationIfPermitted();
      expect(result.status, LocationResultStatus.error);
    });
  });
}
