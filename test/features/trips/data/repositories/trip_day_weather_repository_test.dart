import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/features/trips/data/repositories/trip_day_weather_repository.dart';
import 'package:submersion/features/trips/data/repositories/trip_repository.dart';
import 'package:submersion/features/trips/domain/entities/trip.dart';
import 'package:submersion/features/trips/domain/entities/trip_day_weather.dart';

import '../../../../helpers/test_database.dart';

void main() {
  late TripDayWeatherRepository repository;
  late TripRepository tripRepository;
  late String testTripId;
  late String otherTripId;

  final day1 = DateTime(2026, 3, 8);
  final day2 = DateTime(2026, 3, 9);

  Trip createTestTrip({String name = 'Test Trip'}) {
    final now = DateTime.now();
    return Trip(
      id: '',
      name: name,
      startDate: day1,
      endDate: DateTime(2026, 3, 14),
      createdAt: now,
      updatedAt: now,
    );
  }

  TripDayWeather sample({
    String id = 'w1',
    String? tripId,
    DateTime? date,
    double? airTemp = 21.5,
    CloudCover? cloudCover = CloudCover.clear,
  }) {
    final now = DateTime(2026, 3, 15);
    return TripDayWeather(
      id: id,
      tripId: tripId ?? testTripId,
      date: date ?? day1,
      latitude: 12.16,
      longitude: -68.28,
      airTemp: airTemp,
      cloudCover: cloudCover,
      windSpeed: 6.5,
      windDirection: CurrentDirection.north,
      humidity: 70,
      surfacePressure: 1.011,
      weatherCode: 0,
      fetchedAt: now,
      createdAt: now,
      updatedAt: now,
    );
  }

  setUp(() async {
    await setUpTestDatabase();
    repository = TripDayWeatherRepository();
    tripRepository = TripRepository();

    // Two trips, to prove the queries are scoped. trip_id is a non-nullable
    // FK and beforeOpen turns foreign keys on.
    testTripId = (await tripRepository.createTrip(
      createTestTrip(name: 'Weather Test Trip'),
    )).id;
    otherTripId = (await tripRepository.createTrip(
      createTestTrip(name: 'Other Trip'),
    )).id;
  });

  tearDown(() async {
    await tearDownTestDatabase();
  });

  group('TripDayWeatherRepository', () {
    test('getForTrip is empty before anything is stored', () async {
      expect(await repository.getForTrip(testTripId), isEmpty);
    });

    test('upsert then read back, keyed by date millis', () async {
      await repository.upsert(sample());

      final stored = await repository.getForTrip(testTripId);

      expect(stored, hasLength(1));
      final row = stored[day1.millisecondsSinceEpoch]!;
      expect(row.airTemp, 21.5);
      expect(row.cloudCover, CloudCover.clear);
      expect(row.windDirection, CurrentDirection.north);
      expect(row.weatherCode, 0);
      expect(row.weatherSource, WeatherSource.openMeteo);
      expect(row.latitude, 12.16);
      expect(row.date, day1);
    });

    test('a null payload field round-trips as null', () async {
      await repository.upsert(sample(airTemp: null, cloudCover: null));

      final row = (await repository.getForTrip(
        testTripId,
      ))[day1.millisecondsSinceEpoch]!;

      expect(row.airTemp, isNull);
      expect(row.cloudCover, isNull);
      expect(row.precipitation, isNull);
    });

    test('upserting the same day twice keeps one row', () async {
      await repository.upsert(sample());
      // A different id for the same day: the day is the identity, so this
      // must replace rather than accumulate.
      await repository.upsert(sample(id: 'w2', airTemp: 25));

      final stored = await repository.getForTrip(testTripId);

      expect(stored, hasLength(1));
      expect(stored[day1.millisecondsSinceEpoch]!.airTemp, 25);
    });

    test('a date with a time component is stored under local midnight', () {
      // The repository owns the (trip, date) uniqueness invariant, so it
      // normalizes rather than trusting every caller to. A row keyed on a
      // stray time would be invisible to midnight-keyed lookups and would
      // refetch forever.
      return () async {
        await repository.upsert(sample(date: DateTime(2026, 3, 8, 17, 30)));

        final stored = await repository.getForTrip(testTripId);

        expect(stored.keys.single, day1.millisecondsSinceEpoch);
        expect(stored[day1.millisecondsSinceEpoch]!.date, day1);
      }();
    });

    test('the same day at two times of day stays one row', () async {
      await repository.upsert(sample(date: DateTime(2026, 3, 8, 6)));
      await repository.upsert(
        sample(id: 'w2', date: DateTime(2026, 3, 8, 23), airTemp: 25),
      );

      final stored = await repository.getForTrip(testTripId);

      expect(stored, hasLength(1));
      expect(stored[day1.millisecondsSinceEpoch]!.airTemp, 25);
    });

    test('two different days both persist', () async {
      await repository.upsert(sample());
      await repository.upsert(sample(id: 'w2', date: day2, airTemp: 19));

      final stored = await repository.getForTrip(testTripId);

      expect(stored, hasLength(2));
      expect(stored[day2.millisecondsSinceEpoch]!.airTemp, 19);
    });

    test('getForTrip is scoped to one trip', () async {
      await repository.upsert(sample());
      await repository.upsert(sample(id: 'w2', tripId: otherTripId));

      expect(await repository.getForTrip(testTripId), hasLength(1));
      expect(await repository.getForTrip(otherTripId), hasLength(1));
    });

    test('deleteByTripId removes only that trip rows', () async {
      await repository.upsert(sample());
      await repository.upsert(sample(id: 'w2', tripId: otherTripId));

      await repository.deleteByTripId(testTripId);

      expect(await repository.getForTrip(testTripId), isEmpty);
      expect(await repository.getForTrip(otherTripId), hasLength(1));
    });

    test('deleteByTripId on a trip with no weather is a no-op', () async {
      await repository.deleteByTripId(testTripId);

      expect(await repository.getForTrip(testTripId), isEmpty);
    });

    test('deleting a trip takes its weather rows with it', () async {
      await repository.upsert(sample());
      await repository.upsert(sample(id: 'w2', tripId: otherTripId));

      await tripRepository.deleteTrip(testTripId);

      expect(await repository.getForTrip(testTripId), isEmpty);
      expect(await repository.getForTrip(otherTripId), hasLength(1));
    });

    test('watchWeatherChanges emits after a write', () async {
      final emissions = <void>[];
      final subscription = repository.watchWeatherChanges().listen(
        emissions.add,
      );
      addTearDown(subscription.cancel);

      await repository.upsert(sample());
      await Future<void>.delayed(Duration.zero);

      expect(emissions, isNotEmpty);
    });
  });
}
