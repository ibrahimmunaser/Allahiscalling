import 'package:flutter/material.dart';

import '../services/location_service.dart';

/// Shows a gentle, actionable message for a location request outcome.
void showLocationStatusFeedback(
    BuildContext context, LocationResultStatus status) {
  switch (status) {
    case LocationResultStatus.success:
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Location updated.')),
      );
    case LocationResultStatus.serviceDisabled:
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Location services are off. You can enter your city manually.'),
        ),
      );
    case LocationResultStatus.permissionDenied:
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Location permission was not granted. You can enter your city manually instead.'),
        ),
      );
    case LocationResultStatus.permissionDeniedForever:
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Location permission needed'),
          content: const Text(
            'Location permission is permanently denied. To use your device '
            'location, please open the app settings and allow location '
            'access. You can also enter your city manually.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                LocationService().openAppSettings();
              },
              child: const Text('Open settings'),
            ),
          ],
        ),
      );
    case LocationResultStatus.error:
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Could not detect your location. Please try again or enter it manually.'),
        ),
      );
  }
}
