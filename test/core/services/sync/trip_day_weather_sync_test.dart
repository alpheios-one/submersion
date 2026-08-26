import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/data/repositories/sync_repository.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/core/services/sync/sync_data_serializer.dart';
import 'package:submersion/core/services/sync/sync_service.dart';

import '../../../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late SyncDataSerializer serializer;

  setUp(() async {
    db = await setUpTestDatabase();
    serializer = SyncDataSerializer();
    await db
        .into(db.trips)
        .insert(
          TripsCompanion.insert(
            id: 'trip-1',
            name: 'Bonaire',
            startDate: 0,
            endDate: 0,
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await db
        .into(db.tripDayWeather)
        .insert(
          TripDayWeatherCompanion.insert(
            id: 'w-1',
            tripId: 'trip-1',
            date: DateTime(2026, 3, 8).millisecondsSinceEpoch,
            latitude: 12.16,
            longitude: -68.28,
            airTemp: const Value(24.0),
            cloudCover: const Value('clear'),
            fetchedAt: 1,
            createdAt: 1,
            updatedAt: 1,
          ),
        );
  });

  tearDown(tearDownTestDatabase);

  test('tripDayWeather export, fetch, upsert, and delete round-trip', () async {
    final record = await serializer.fetchRecord('tripDayWeather', 'w-1');
    expect(record, isNotNull);
    expect(record!['airTemp'], 24.0);
    expect(record['cloudCover'], 'clear');

    // A remote edit merges over the local row (LWW payload apply).
    await serializer.upsertRecord('tripDayWeather', {
      ...record,
      'airTemp': 26.0,
      'updatedAt': 2,
    });
    final merged = await serializer.fetchRecord('tripDayWeather', 'w-1');
    expect(merged!['airTemp'], 26.0);

    expect(await serializer.recordIdsFor('tripDayWeather'), contains('w-1'));

    await serializer.deleteRecord('tripDayWeather', 'w-1');
    expect(await serializer.fetchRecord('tripDayWeather', 'w-1'), isNull);
  });

  test('the delta export filters on the row own hlc', () async {
    await (db.update(
      db.tripDayWeather,
    )..where((t) => t.id.equals('w-1'))).write(
      const TripDayWeatherCompanion(hlc: Value('2026-08-16T00:00:00.000-0000')),
    );

    Future<int> changesetCount(String? watermark) async {
      final payload = await serializer.exportChangeset(
        deviceId: 'device-1',
        hlcWatermark: watermark,
        deletions: const [],
      );
      return payload.data.tripDayWeather.length;
    }

    // A base carries the row; a watermark newer than it excludes it; an older
    // watermark includes it.
    expect(await changesetCount(null), 1);
    expect(await changesetCount('2026-08-17T00:00:00.000-0000'), 0);
    expect(await changesetCount('2026-08-15T00:00:00.000-0000'), 1);
  });

  test('tripDayWeather is registered as an hlc target', () {
    // An omission here is silent: _stampHlc no-ops on an unknown entity type,
    // the column stays NULL, and the incremental export's hlc > watermark
    // filter then excludes the row from every changeset forever.
    expect(SyncRepository.hlcTargets.containsKey('tripDayWeather'), isTrue);
    expect(
      SyncRepository.hlcTargets['tripDayWeather']!.table,
      'trip_day_weather',
    );
  });

  test('tripDayWeather carries an updatedAt flag', () {
    expect(SyncService.entityHasUpdatedAt['tripDayWeather'], isTrue);
  });
}
