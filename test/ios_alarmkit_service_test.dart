import 'package:allah_invites_you_to_salah/models/salah_prayer.dart';
import 'package:allah_invites_you_to_salah/services/ios_alarmkit_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Direct unit tests for [IosAlarmKitService] itself (not the [AlarmKitClient]
/// fakes used by the hybrid-scheduler tests).
///
/// This Windows test host is never iOS, so `Platform.isIOS` is always false
/// and every method's platform-gated early-return branch is what actually
/// runs here — never the MethodChannel invoke path. That gate is precisely
/// what makes these branches safe to exercise without a real iOS host: they
/// are required to return a deterministic "unavailable" result rather than
/// touching the channel at all. The channel invoke branches themselves
/// (`schedulePrayerAlarm` success/failure, `cancelAlarm`, etc.) can only be
/// exercised on a Mac/device — see IOS_STRESS_TEST_REPORT.md.
void main() {
  late IosAlarmKitService service;

  setUp(() {
    service = IosAlarmKitService();
  });

  tearDown(() {
    service.dispose();
  });

  test('IosAlarmKitService implements AlarmKitClient', () {
    expect(service, isA<AlarmKitClient>());
  });

  group('non-iOS platform gate (this test host is never iOS)', () {
    test('isAvailable is false', () async {
      expect(await service.isAvailable(), isFalse);
    });

    test('authorizationStatus is unavailable', () async {
      expect(await service.authorizationStatus(), 'unavailable');
    });

    test('isAuthorized is false', () async {
      expect(await service.isAuthorized, isFalse);
    });

    test(
      'requestAuthorization returns unavailable without prompting',
      () async {
        expect(await service.requestAuthorization(), 'unavailable');
      },
    );

    test('openSystemSettings completes without throwing', () async {
      await expectLater(service.openSystemSettings(), completes);
    });

    test('getPendingAnswer resolves to null', () async {
      expect(await service.getPendingAnswer(), isNull);
    });

    test('clearPendingAnswer completes without throwing', () async {
      await expectLater(service.clearPendingAnswer(), completes);
    });

    test('pendingAlarmIds resolves to an empty list', () async {
      expect(await service.pendingAlarmIds(), isEmpty);
    });

    test('ensureListening is idempotent and never throws', () async {
      service.ensureListening();
      service.ensureListening();
      service.ensureListening();
    });
  });

  group('schedulePrayerAlarm without AlarmKit available', () {
    test('reports AlarmKitOutcome.unavailable, never AlarmKit.notAuthorized or '
        '.scheduled', () async {
      final result = await service.schedulePrayerAlarm(
        prayer: SalahPrayer.fajr,
        scheduledAt: DateTime.utc(2026, 12, 1, 5, 30),
      );
      expect(result.outcome, AlarmKitOutcome.unavailable);
      expect(result.success, isFalse);
      expect(result.error, isNull);
    });

    test('still returns the deterministic alarmId even on failure, so a '
        'caller can key cleanup/cancellation off it', () async {
      final scheduledAt = DateTime.utc(2026, 12, 1, 5, 30);
      final result = await service.schedulePrayerAlarm(
        prayer: SalahPrayer.fajr,
        scheduledAt: scheduledAt,
      );
      expect(
        result.alarmId,
        IosAlarmKitService.stableAlarmId(SalahPrayer.fajr, scheduledAt),
      );
    });

    test(
      'optional soundName does not change the unavailable outcome',
      () async {
        final result = await service.schedulePrayerAlarm(
          prayer: SalahPrayer.isha,
          scheduledAt: DateTime.utc(2026, 12, 1, 20, 0),
          soundName: 'adhan.caf',
        );
        expect(result.outcome, AlarmKitOutcome.unavailable);
      },
    );
  });

  group('cancellation is always a safe no-op without AlarmKit', () {
    test('cancelAlarm by prayer/time does not throw', () async {
      await expectLater(
        service.cancelAlarm(
          prayer: SalahPrayer.dhuhr,
          scheduledAt: DateTime.utc(2026, 12, 1, 12, 0),
        ),
        completes,
      );
    });

    test('cancelAlarmId does not throw', () async {
      await expectLater(service.cancelAlarmId('any-id'), completes);
    });

    test('cancelAll does not throw', () async {
      await expectLater(service.cancelAll(), completes);
    });
  });

  test('scheduleDebugAlarm delegates to schedulePrayerAlarm and does not '
      'throw even though AlarmKit is unavailable on this host', () async {
    await expectLater(
      service.scheduleDebugAlarm(delay: const Duration(seconds: 1)),
      completes,
    );
  });

  group('AlarmKitScheduleResult', () {
    test('success is true only for AlarmKitOutcome.scheduled', () {
      const scheduled = AlarmKitScheduleResult(
        outcome: AlarmKitOutcome.scheduled,
        alarmId: 'a',
      );
      const unavailable = AlarmKitScheduleResult(
        outcome: AlarmKitOutcome.unavailable,
        alarmId: 'a',
      );
      const notAuthorized = AlarmKitScheduleResult(
        outcome: AlarmKitOutcome.notAuthorized,
        alarmId: 'a',
      );
      const failed = AlarmKitScheduleResult(
        outcome: AlarmKitOutcome.failed,
        alarmId: 'a',
        error: 'boom',
      );
      expect(scheduled.success, isTrue);
      expect(unavailable.success, isFalse);
      expect(notAuthorized.success, isFalse);
      expect(failed.success, isFalse);
      expect(failed.error, 'boom');
    });
  });
}
