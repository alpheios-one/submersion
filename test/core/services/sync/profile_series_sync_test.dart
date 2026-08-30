import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/core/data/repositories/sync_repository.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/core/services/database_service.dart';
import 'package:submersion/core/services/sync/sync_clock.dart';
import 'package:submersion/core/services/sync/sync_data_serializer.dart';
import 'package:submersion/core/services/sync/sync_service.dart';
import 'package:submersion/features/dive_log/data/repositories/dive_repository_impl.dart';
import 'package:submersion/features/dive_log/data/repositories/profile_series_repository.dart';
import 'package:submersion/features/dive_log/data/repositories/tank_pressure_series_repository.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_sample.dart';
import 'package:submersion/features/dive_log/domain/codecs/tank_pressure_series_codec.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart'
    as domain;

import '../../../helpers/fake_cloud_storage_provider.dart';
import '../../../helpers/test_database.dart';

/// Registers `diveProfileSeries` and `tankPressureSeries` in the sync
/// serializer and service (plan 2d, task 1). Before this, the series tables
/// were invisible to sync: a device that migrated its `dive_profiles` /
/// `tank_pressure_profiles` rows into packed series never pushed them, and a
/// peer never received them.
///
/// Uses two genuinely separate in-memory [AppDatabase] instances, swapped
/// into [DatabaseService] between "device" phases, matching
/// consolidation_sync_roundtrip_test.dart.
void main() {
  late AppDatabase dbA;
  AppDatabase? dbB;
  late FakeCloudStorageProvider cloud;

  setUp(() {
    dbB = null;
    cloud = FakeCloudStorageProvider();
  });

  tearDown(() async {
    DatabaseService.instance.resetForTesting();
    SyncClock.instance.reset();
    await dbA.close();
    final b = dbB;
    if (b != null) {
      await b.close();
    }
  });

  SyncService buildService() => SyncService(
    syncRepository: SyncRepository(),
    serializer: SyncDataSerializer(),
    cloudProvider: cloud,
  );

  /// Makes [db] the active database for every repository/service in this
  /// test and drops the process-wide HLC clock so it re-seeds from [db]'s
  /// own sync metadata and row HLCs, rather than carrying over whichever
  /// device was previously active.
  void switchTo(AppDatabase db) {
    DatabaseService.instance.setTestDatabase(db);
    SyncClock.instance.reset();
  }

  Future<void> seedFkPrereqs(AppDatabase db) async {
    await db
        .into(db.divers)
        .insert(
          const DiversCompanion(
            id: Value('diver1'),
            name: Value('diver1'),
            createdAt: Value(0),
            updatedAt: Value(0),
          ),
        );
    for (final computerId in ['comp-t', 'comp-s']) {
      await db
          .into(db.diveComputers)
          .insert(
            DiveComputersCompanion.insert(
              id: computerId,
              name: computerId,
              createdAt: 0,
              updatedAt: 0,
            ),
          );
    }
    await db
        .into(db.tags)
        .insert(
          TagsCompanion.insert(
            id: 'tag1',
            name: 'tag1',
            createdAt: 0,
            updatedAt: 0,
          ),
        );
  }

  Future<void> seedBareDive(AppDatabase db, String id) async {
    await db
        .into(db.dives)
        .insert(
          DivesCompanion.insert(
            id: id,
            diveDateTime: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
            createdAt: 0,
            updatedAt: 0,
          ),
        );
  }

  test(
    'a series pushed by A arrives on B byte for byte and reads back',
    () async {
      dbB = await setUpTestDatabase();
      dbA = await setUpTestDatabase();
      switchTo(dbA);
      await seedFkPrereqs(dbA);
      await DiveRepository().createDive(
        domain.Dive(
          id: 'd1',
          dateTime: DateTime.utc(2026, 1, 1, 10),
          profile: const [
            domain.DiveProfilePoint(timestamp: 0, depth: 0.0),
            domain.DiveProfilePoint(
              timestamp: 60,
              depth: 18.5,
              decoType: 2,
              ceiling: 3.0,
            ),
          ],
        ),
      );
      final rowOnA = (await ProfileSeriesRepository().getRowsForDives([
        'd1',
      ])).single;
      expect((await buildService().performSync()).isSuccess, isTrue);

      switchTo(dbB!);
      await seedFkPrereqs(dbB!);
      expect((await buildService().performSync()).isSuccess, isTrue);
      final rowOnB = (await ProfileSeriesRepository().getRowsForDives([
        'd1',
      ])).single;
      expect(rowOnB.id, rowOnA.id);
      expect(rowOnB.samples, rowOnA.samples);
      expect(rowOnB.hasDecoStop, isTrue);
      expect(
        (await DiveRepository().getDiveProfile('d1')).map((p) => p.depth),
        [0.0, 18.5],
      );
    },
  );

  test('a series deleted on A is tombstoned and removed on B', () async {
    dbB = await setUpTestDatabase();
    dbA = await setUpTestDatabase();
    switchTo(dbA);
    await seedFkPrereqs(dbA);
    await DiveRepository().createDive(
      domain.Dive(
        id: 'd1',
        dateTime: DateTime.utc(2026, 1, 1, 10),
        profile: const [
          domain.DiveProfilePoint(timestamp: 0, depth: 0.0),
          domain.DiveProfilePoint(timestamp: 60, depth: 18.5),
        ],
      ),
    );
    expect((await buildService().performSync()).isSuccess, isTrue);

    switchTo(dbB!);
    await seedFkPrereqs(dbB!);
    expect((await buildService().performSync()).isSuccess, isTrue);
    expect(await ProfileSeriesRepository().getSeriesForDive('d1'), isNotEmpty);

    switchTo(dbA);
    await ProfileSeriesRepository().deleteForDive('d1');
    expect((await buildService().performSync()).isSuccess, isTrue);

    switchTo(dbB!);
    expect((await buildService().performSync()).isSuccess, isTrue);
    expect(await ProfileSeriesRepository().getSeriesForDive('d1'), isEmpty);
  });

  test(
    'fetchRecord carries samples as base64 and upsertRecord round-trips it',
    () async {
      dbA = await setUpTestDatabase();
      switchTo(dbA);
      await seedFkPrereqs(dbA);
      await seedBareDive(dbA, 'd1');
      final id = await ProfileSeriesRepository().insertSeries(
        diveId: 'd1',
        samples: const [ProfileSample(timestamp: 0, depth: 1.0)],
        now: 1000,
      );
      final json = await SyncDataSerializer().fetchRecord(
        'diveProfileSeries',
        id,
      );
      expect(json!['samples'], isA<String>());
      await ProfileSeriesRepository().deleteForDive('d1');
      await SyncDataSerializer().upsertRecord('diveProfileSeries', json);
      expect(
        (await ProfileSeriesRepository().getSeriesForDive(
          'd1',
        )).single.samples.single.depth,
        1.0,
      );
    },
  );

  test('a corrupt peer blob is skipped, never written', () async {
    dbA = await setUpTestDatabase();
    switchTo(dbA);
    await seedFkPrereqs(dbA);
    await seedBareDive(dbA, 'd1');
    final id = await ProfileSeriesRepository().insertSeries(
      diveId: 'd1',
      samples: const [ProfileSample(timestamp: 0, depth: 1.0)],
      now: 1000,
    );
    final json = await SyncDataSerializer().fetchRecord(
      'diveProfileSeries',
      id,
    );
    await ProfileSeriesRepository().deleteForDive('d1');
    final corrupted = {
      ...json!,
      'samples': base64Encode(const [1, 2, 3]),
    };
    await SyncDataSerializer().upsertRecord('diveProfileSeries', corrupted);
    expect(await ProfileSeriesRepository().getSeriesForDive('d1'), isEmpty);
  });

  test(
    'a peer blob whose sample count disagrees with the header is skipped',
    () async {
      dbA = await setUpTestDatabase();
      switchTo(dbA);
      await seedFkPrereqs(dbA);
      await seedBareDive(dbA, 'd1');
      final id = await ProfileSeriesRepository().insertSeries(
        diveId: 'd1',
        samples: const [ProfileSample(timestamp: 0, depth: 1.0)],
        now: 1000,
      );
      final json = await SyncDataSerializer().fetchRecord(
        'diveProfileSeries',
        id,
      );
      await ProfileSeriesRepository().deleteForDive('d1');
      final tampered = {...json!, 'sampleCount': 99};
      await SyncDataSerializer().upsertRecord('diveProfileSeries', tampered);
      expect(await ProfileSeriesRepository().getSeriesForDive('d1'), isEmpty);
    },
  );

  test(
    'a tank pressure series pushed by A arrives on B byte for byte',
    () async {
      dbB = await setUpTestDatabase();
      dbA = await setUpTestDatabase();
      switchTo(dbA);
      await seedFkPrereqs(dbA);
      await seedBareDive(dbA, 'd1');
      await dbA
          .into(dbA.diveTanks)
          .insert(DiveTanksCompanion.insert(id: 'tank1', diveId: 'd1'));
      await TankPressureSeriesRepository().insertSeries(
        diveId: 'd1',
        tankId: 'tank1',
        samples: const [
          TankPressureSample(timestamp: 0, pressure: 200.0),
          TankPressureSample(timestamp: 60, pressure: 180.0),
        ],
        now: 1000,
      );
      final rowOnA = (await TankPressureSeriesRepository().getRowsForDives([
        'd1',
      ])).single;
      expect((await buildService().performSync()).isSuccess, isTrue);

      switchTo(dbB!);
      await seedFkPrereqs(dbB!);
      expect((await buildService().performSync()).isSuccess, isTrue);
      final rowOnB = (await TankPressureSeriesRepository().getRowsForDives([
        'd1',
      ])).single;
      expect(rowOnB.id, rowOnA.id);
      expect(rowOnB.samples, rowOnA.samples);
      expect(rowOnB.tankId, 'tank1');
    },
  );

  test('fetchRecord carries tank pressure samples as base64 and '
      'upsertRecord round-trips it', () async {
    dbA = await setUpTestDatabase();
    switchTo(dbA);
    await seedFkPrereqs(dbA);
    await seedBareDive(dbA, 'd1');
    await dbA
        .into(dbA.diveTanks)
        .insert(DiveTanksCompanion.insert(id: 'tank1', diveId: 'd1'));
    final id = await TankPressureSeriesRepository().insertSeries(
      diveId: 'd1',
      tankId: 'tank1',
      samples: const [TankPressureSample(timestamp: 0, pressure: 200.0)],
      now: 1000,
    );
    final json = await SyncDataSerializer().fetchRecord(
      'tankPressureSeries',
      id,
    );
    expect(json!['samples'], isA<String>());
    await TankPressureSeriesRepository().deleteForDive('d1');
    await SyncDataSerializer().upsertRecord('tankPressureSeries', json);
    expect(
      (await TankPressureSeriesRepository().getSeriesForDive(
        'd1',
      )).single.samples.single.pressure,
      200.0,
    );
  });
}
