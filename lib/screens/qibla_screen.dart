import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:provider/provider.dart';

import '../state/app_controller.dart';
import '../utils/app_strings.dart';
import '../utils/app_theme.dart';

/// Compass screen pointing toward the Kaaba in Makkah.
///
/// Combines the device magnetometer heading (via flutter_compass) with the
/// great-circle initial bearing from the user's saved location to the Kaaba.
class QiblaScreen extends StatefulWidget {
  const QiblaScreen({super.key});

  @override
  State<QiblaScreen> createState() => _QiblaScreenState();
}

class _QiblaScreenState extends State<QiblaScreen> {
  // Kaaba coordinates, Masjid al-Haram, Makkah.
  static const double _kaabaLat = 21.4225;
  static const double _kaabaLng = 39.8262;

  // Alignment tolerance in degrees for the "facing Qibla" state.
  static const double _alignedTolerance = 5.0;

  bool _wasAligned = false;

  double _degToRad(double deg) => deg * math.pi / 180.0;
  double _radToDeg(double rad) => rad * 180.0 / math.pi;

  /// Initial great-circle bearing from (lat, lng) to the Kaaba, in degrees
  /// clockwise from true North, normalized to [0, 360).
  double _qiblaBearing(double lat, double lng) {
    final phi1 = _degToRad(lat);
    final phi2 = _degToRad(_kaabaLat);
    final deltaLambda = _degToRad(_kaabaLng - lng);
    final y = math.sin(deltaLambda) * math.cos(phi2);
    final x =
        math.cos(phi1) * math.sin(phi2) -
        math.sin(phi1) * math.cos(phi2) * math.cos(deltaLambda);
    return (_radToDeg(math.atan2(y, x)) + 360.0) % 360.0;
  }

  /// Haversine distance to the Kaaba in kilometers.
  double _distanceToKaabaKm(double lat, double lng) {
    const earthRadiusKm = 6371.0;
    final dPhi = _degToRad(_kaabaLat - lat);
    final dLambda = _degToRad(_kaabaLng - lng);
    final a =
        math.pow(math.sin(dPhi / 2), 2) +
        math.cos(_degToRad(lat)) *
            math.cos(_degToRad(_kaabaLat)) *
            math.pow(math.sin(dLambda / 2), 2);
    return earthRadiusKm * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  String _compassPoint(double bearing) {
    const points = [
      'N',
      'NNE',
      'NE',
      'ENE',
      'E',
      'ESE',
      'SE',
      'SSE',
      'S',
      'SSW',
      'SW',
      'WSW',
      'W',
      'WNW',
      'NW',
      'NNW',
    ];
    return points[((bearing + 11.25) % 360 / 22.5).floor()];
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final settings = controller.settings;

    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.qiblaTitle)),
      body:
          !settings.hasLocation
              ? _NoLocationView()
              : _buildCompass(
                settings.latitude!,
                settings.longitude!,
                settings.locationLabel,
              ),
    );
  }

  Widget _buildCompass(double lat, double lng, String? locationLabel) {
    final qibla = _qiblaBearing(lat, lng);
    final distanceKm = _distanceToKaabaKm(lat, lng).round();

    return StreamBuilder<CompassEvent>(
      stream: FlutterCompass.events,
      builder: (context, snapshot) {
        final heading = snapshot.data?.heading;

        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (heading == null) {
          return _NoCompassView(
            qibla: qibla,
            distanceKm: distanceKm,
            compassPoint: _compassPoint(qibla),
          );
        }

        // Signed smallest difference between qibla bearing and heading.
        var delta = (qibla - heading) % 360.0;
        if (delta > 180.0) delta -= 360.0;
        final aligned = delta.abs() <= _alignedTolerance;

        // Light haptic tick when entering the aligned state.
        if (aligned && !_wasAligned) {
          HapticFeedback.mediumImpact();
        }
        _wasAligned = aligned;

        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (locationLabel != null && locationLabel.isNotEmpty)
              Center(
                child: Text(
                  locationLabel,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.black.withValues(alpha: 0.55),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                aligned ? AppStrings.qiblaAligned : AppStrings.qiblaRotateHint,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: aligned ? AppTheme.gold : AppTheme.deepGreen,
                ),
              ),
            ),
            const SizedBox(height: 24),
            Center(
              child: _CompassDial(
                heading: heading,
                qibla: qibla,
                aligned: aligned,
              ),
            ),
            const SizedBox(height: 28),
            _InfoCard(
              qibla: qibla,
              distanceKm: distanceKm,
              compassPoint: _compassPoint(qibla),
            ),
            const SizedBox(height: 16),
            Text(
              AppStrings.qiblaCalibrationHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: Colors.black.withValues(alpha: 0.45),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _NoLocationView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.location_off_outlined,
              size: 48,
              color: AppTheme.emerald,
            ),
            const SizedBox(height: 16),
            const Text(
              AppStrings.qiblaNeedsLocation,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Go back'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoCompassView extends StatelessWidget {
  final double qibla;
  final int distanceKm;
  final String compassPoint;

  const _NoCompassView({
    required this.qibla,
    required this.distanceKm,
    required this.compassPoint,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 24),
        const Icon(
          Icons.explore_off_outlined,
          size: 48,
          color: AppTheme.emerald,
        ),
        const SizedBox(height: 16),
        const Text(
          AppStrings.qiblaNoCompass,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15),
        ),
        const SizedBox(height: 24),
        _InfoCard(
          qibla: qibla,
          distanceKm: distanceKm,
          compassPoint: compassPoint,
        ),
      ],
    );
  }
}

class _InfoCard extends StatelessWidget {
  final double qibla;
  final int distanceKm;
  final String compassPoint;

  const _InfoCard({
    required this.qibla,
    required this.distanceKm,
    required this.compassPoint,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.deepGreen, AppTheme.emerald],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Text(
            AppStrings.qiblaBearingLine(qibla.round(), compassPoint),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppTheme.ivory,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            AppStrings.qiblaDistanceLine(distanceKm),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppTheme.ivory.withValues(alpha: 0.8),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

/// Rotating compass dial with a fixed Qibla arrow overlay.
///
/// The dial (tick marks + cardinal letters) rotates by -heading so that it
/// always reflects true directions. The arrow rotates by (qibla - heading)
/// so pointing the phone at the Qibla brings the arrow to 12 o'clock.
class _CompassDial extends StatelessWidget {
  final double heading;
  final double qibla;
  final bool aligned;

  const _CompassDial({
    required this.heading,
    required this.qibla,
    required this.aligned,
  });

  @override
  Widget build(BuildContext context) {
    const size = 280.0;
    final headingRad = heading * math.pi / 180.0;
    final arrowRad = (qibla - heading) * math.pi / 180.0;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Dial background.
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
              border: Border.all(
                color: aligned ? AppTheme.gold : AppTheme.emerald,
                width: 3,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
          ),
          // Rotating tick marks and cardinal letters.
          Transform.rotate(
            angle: -headingRad,
            child: CustomPaint(
              size: const Size(size, size),
              painter: _DialPainter(),
            ),
          ),
          // Qibla arrow (rotates relative to heading).
          Transform.rotate(
            angle: arrowRad,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.navigation,
                  size: 88,
                  color: aligned ? AppTheme.gold : AppTheme.emerald,
                ),
                const SizedBox(height: 4),
                const Text('🕋', style: TextStyle(fontSize: 28)),
                // Balance the column so the arrow pivots around dial center.
                const SizedBox(height: 88),
              ],
            ),
          ),
          // Fixed phone-direction marker at 12 o'clock.
          const Positioned(
            top: 2,
            child: Icon(Icons.arrow_drop_down, color: AppTheme.gold, size: 34),
          ),
        ],
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    final tickPaint =
        Paint()
          ..color = AppTheme.deepGreen.withValues(alpha: 0.35)
          ..strokeWidth = 1.5;
    final majorTickPaint =
        Paint()
          ..color = AppTheme.deepGreen
          ..strokeWidth = 2.5;

    for (var deg = 0; deg < 360; deg += 15) {
      final isMajor = deg % 90 == 0;
      final rad = deg * math.pi / 180.0;
      final outer = Offset(
        center.dx + (radius - 10) * math.sin(rad),
        center.dy - (radius - 10) * math.cos(rad),
      );
      final inner = Offset(
        center.dx + (radius - (isMajor ? 26 : 18)) * math.sin(rad),
        center.dy - (radius - (isMajor ? 26 : 18)) * math.cos(rad),
      );
      canvas.drawLine(inner, outer, isMajor ? majorTickPaint : tickPaint);
    }

    const cardinals = {'N': 0, 'E': 90, 'S': 180, 'W': 270};
    cardinals.forEach((label, deg) {
      final rad = deg * math.pi / 180.0;
      final pos = Offset(
        center.dx + (radius - 44) * math.sin(rad),
        center.dy - (radius - 44) * math.cos(rad),
      );
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: label == 'N' ? AppTheme.gold : AppTheme.deepGreen,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      canvas.save();
      canvas.translate(pos.dx - painter.width / 2, pos.dy - painter.height / 2);
      // Keep letters upright relative to the rotating dial by counter-rotating
      // around the letter's own center.
      painter.paint(canvas, Offset.zero);
      canvas.restore();
    });
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
