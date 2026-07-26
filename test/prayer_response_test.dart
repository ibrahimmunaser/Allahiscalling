import 'package:allah_invites_you_to_salah/models/prayer_response.dart';
import 'package:allah_invites_you_to_salah/models/salah_prayer.dart';
import 'package:allah_invites_you_to_salah/repositories/prayer_settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PrayerSettingsRepository repository;
  final day = DateTime(2026, 7, 4, 14);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repository = PrayerSettingsRepository(
      await SharedPreferences.getInstance(),
    );
  });

  group('four distinct response states', () {
    test('answered is persisted and readable', () async {
      final at = DateTime(2026, 7, 4, 13, 6);
      await repository.savePrayerResponse(
        day,
        SalahPrayer.dhuhr,
        PrayerResponseState.answered,
        at,
      );

      expect(
        repository.prayerResponse(day, SalahPrayer.dhuhr),
        PrayerResponseState.answered,
      );
      expect(repository.prayerAnsweredAt(day, SalahPrayer.dhuhr), at);
      // Answered is not completed.
      expect(repository.isPrayerCompleted(day, SalahPrayer.dhuhr), isFalse);
    });

    test('declined is persisted and is not answered', () async {
      await repository.savePrayerResponse(
        day,
        SalahPrayer.asr,
        PrayerResponseState.declined,
        DateTime(2026, 7, 4, 17, 2),
      );

      expect(
        repository.prayerResponse(day, SalahPrayer.asr),
        PrayerResponseState.declined,
      );
      // A declined prayer must never read as answered (no completion card).
      expect(repository.prayerAnsweredAt(day, SalahPrayer.asr), isNull);
    });

    test(
      'dismissed is persisted and is neither answered nor declined',
      () async {
        await repository.savePrayerResponse(
          day,
          SalahPrayer.maghrib,
          PrayerResponseState.dismissed,
          DateTime(2026, 7, 4, 21, 40),
        );

        expect(
          repository.prayerResponse(day, SalahPrayer.maghrib),
          PrayerResponseState.dismissed,
        );
        expect(repository.prayerAnsweredAt(day, SalahPrayer.maghrib), isNull);
      },
    );

    test('marked complete is tracked independently of the response', () async {
      // Completed without ever touching the reminder (user prayed on their
      // own initiative).
      await repository.savePrayerCompletion(day, SalahPrayer.fajr);

      expect(repository.isPrayerCompleted(day, SalahPrayer.fajr), isTrue);
      expect(repository.prayerResponse(day, SalahPrayer.fajr), isNull);
    });

    test('no state at all reads as null everywhere', () {
      expect(repository.prayerResponse(day, SalahPrayer.isha), isNull);
      expect(repository.prayerAnsweredAt(day, SalahPrayer.isha), isNull);
      expect(repository.isPrayerCompleted(day, SalahPrayer.isha), isFalse);
    });
  });

  group('state transitions', () {
    test(
      'latest response wins: dismissed then answered ends answered',
      () async {
        await repository.savePrayerResponse(
          day,
          SalahPrayer.dhuhr,
          PrayerResponseState.dismissed,
          DateTime(2026, 7, 4, 13, 7),
        );
        await repository.savePrayerResponse(
          day,
          SalahPrayer.dhuhr,
          PrayerResponseState.answered,
          DateTime(2026, 7, 4, 13, 30),
        );

        expect(
          repository.prayerResponse(day, SalahPrayer.dhuhr),
          PrayerResponseState.answered,
        );
        expect(
          repository.prayerAnsweredAt(day, SalahPrayer.dhuhr),
          DateTime(2026, 7, 4, 13, 30),
        );
      },
    );

    test('responses are per-prayer and per-day', () async {
      await repository.savePrayerResponse(
        day,
        SalahPrayer.dhuhr,
        PrayerResponseState.answered,
        DateTime(2026, 7, 4, 13, 6),
      );

      expect(repository.prayerResponse(day, SalahPrayer.asr), isNull);
      final nextDay = day.add(const Duration(days: 1));
      expect(repository.prayerResponse(nextDay, SalahPrayer.dhuhr), isNull);
    });
  });
}
