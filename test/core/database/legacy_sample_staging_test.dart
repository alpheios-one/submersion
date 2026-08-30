import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/core/database/database.dart';
import 'package:submersion/core/database/legacy_sample_staging.dart';
import 'package:submersion/core/database/profile_series_pack.dart';
import 'package:submersion/features/dive_log/data/repositories/profile_series_repository.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_sample.dart';
import 'package:submersion/features/dive_log/domain/entities/profile_series_identity.dart';

import '../../helpers/test_database.dart';

/// [ensureLegacyStagingTables] / [stageLegacyProfileRows] /
/// [stageLegacyTankRows] / [packStagedLegacyRows]: the receive-side shim that
/// replaces the dropped `dive_profiles` / `tank_pressure_profiles` tables
/// (v183, plan 2e task 2) for an older peer's row-per-sample rows.
void main() {
  late AppDatabase db;

  setUp(() async {
    db = await setUpTestDatabase();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db
        .into(db.dives)
        .insert(
          DivesCompanion.insert(
            id: 'dive-1',
            diveDateTime: now,
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db
        .into(db.diveComputers)
        .insert(
          DiveComputersCompanion.insert(
            id: 'comp-1',
            name: 'Comp 1',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db
        .into(db.diveDataSources)
        .insert(
          DiveDataSourcesCompanion.insert(
            id: 'src-1',
            diveId: 'dive-1',
            computerId: const Value('comp-1'),
            isPrimary: const Value(true),
            importedAt: DateTime.fromMillisecondsSinceEpoch(now),
            createdAt: DateTime.fromMillisecondsSinceEpoch(now),
          ),
        );
    await db
        .into(db.diveTanks)
        .insert(DiveTanksCompanion.insert(id: 'tank-a', diveId: 'dive-1'));
  });

  tearDown(tearDownTestDatabase);

  test('wire rows land in the staging table with snake_case columns', () async {
    await ensureLegacyStagingTables(db);
    final n = await stageLegacyProfileRows(db, [
      {
        'id': 'p1',
        'diveId': 'dive-1',
        'computerId': null,
        'sourceId': null,
        'isPrimary': true,
        'timestamp': 0,
        'depth': 0.0,
        'ppO2': 1.2,
        'o2SensorMv1': 55,
        'heartRateSource': 'chest',
        'unknownKey': 42,
      },
      {
        'id': 'p2',
        'diveId': 'dive-1',
        'isPrimary': true,
        'timestamp': 30,
        'depth': 12.0,
      },
    ]);
    expect(n, 2);
    final rows = await db
        .customSelect(
          'SELECT id, dive_id, is_primary, pp_o2, o2_sensor_mv1, '
          'heart_rate_source FROM dive_profiles_inbound ORDER BY timestamp',
        )
        .get();
    expect(rows.first.data['pp_o2'], 1.2);
    expect(rows.first.data['o2_sensor_mv1'], 55);
    expect(rows.first.data['heart_rate_source'], 'chest');
    expect(rows.first.data['is_primary'], 1);
  });

  test(
    'packStagedLegacyRows packs into series and empties the staging tables',
    () async {
      await ensureLegacyStagingTables(db);
      await stageLegacyProfileRows(db, [
        {
          'id': 'p1',
          'diveId': 'dive-1',
          'isPrimary': true,
          'timestamp': 0,
          'depth': 0.0,
        },
        {
          'id': 'p2',
          'diveId': 'dive-1',
          'isPrimary': true,
          'timestamp': 30,
          'depth': 12.0,
        },
      ]);
      await stageLegacyTankRows(db, [
        {
          'id': 't1',
          'diveId': 'dive-1',
          'tankId': 'tank-a',
          'timestamp': 0,
          'pressure': 200.0,
        },
      ]);
      final report = await packStagedLegacyRows(db);
      expect(report.profileSeries, 1);
      expect(report.tankSeries, 1);
      final series = await ProfileSeriesRepository().getSeriesForDive('dive-1');
      expect(series.single.samples.map((s) => s.depth), [0.0, 12.0]);
      expect(
        series.single.id,
        profileSeriesMigratedId(
          diveId: 'dive-1',
          computerId: null,
          sourceId: null,
          isPrimary: true,
        ),
      );
      expect(
        (await db
                .customSelect('SELECT COUNT(*) AS n FROM dive_profiles_inbound')
                .getSingle())
            .data['n'],
        0,
      );
      expect(
        (await db
                .customSelect(
                  'SELECT COUNT(*) AS n FROM tank_pressure_profiles_inbound',
                )
                .getSingle())
            .data['n'],
        0,
      );
    },
  );

  test('a dive that already has a series ignores staged rows, and the staging '
      'is still emptied', () async {
    await ProfileSeriesRepository().insertSeries(
      diveId: 'dive-1',
      samples: const [ProfileSample(timestamp: 0, depth: 1.0)],
      now: 1000,
    );
    final before = (await ProfileSeriesRepository().getSeriesForDive(
      'dive-1',
    )).single;

    await ensureLegacyStagingTables(db);
    await stageLegacyProfileRows(db, [
      {
        'id': 'p-stale',
        'diveId': 'dive-1',
        'isPrimary': true,
        'timestamp': 0,
        'depth': 99.0,
      },
    ]);
    final report = await packStagedLegacyRows(db);
    expect(report.profileSeries, 0);

    final after = (await ProfileSeriesRepository().getSeriesForDive(
      'dive-1',
    )).single;
    expect(after.id, before.id);
    expect(
      after.samples.map((s) => s.depth),
      before.samples.map((s) => s.depth),
    );
    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM dive_profiles_inbound')
              .getSingle())
          .data['n'],
      0,
    );
  });

  test('ensureLegacyStagingTables is idempotent and survives a missing legacy '
      'table', () async {
    await ensureLegacyStagingTables(db);
    await ensureLegacyStagingTables(db);
    expect(await packStagedLegacyRows(db), isA<ProfilePackReport>());
  });

  test(
    'a pack failure leaves the staged rows in place for the next apply',
    () async {
      await ensureLegacyStagingTables(db);
      await stageLegacyProfileRows(db, [
        {
          'id': 'p1',
          'diveId': 'dive-1',
          'isPrimary': true,
          'timestamp': 0,
          'depth': 0.0,
        },
        {
          'id': 'p2',
          'diveId': 'dive-1',
          'isPrimary': true,
          'timestamp': 30,
          'depth': 12.0,
        },
      ]);

      // The malformed-dive_profile_series trick from backstop_resilience_test
      // and legacy_sample_entities_inbound_test: a series table missing the
      // summary/samples columns makes every packer INSERT fail.
      await db.customStatement('DROP TABLE dive_profile_series');
      await db.customStatement('''
          CREATE TABLE dive_profile_series (
            id TEXT NOT NULL PRIMARY KEY,
            dive_id TEXT NOT NULL,
            computer_id TEXT,
            source_id TEXT,
            is_primary INTEGER NOT NULL DEFAULT 1
          )
        ''');

      await expectLater(packStagedLegacyRows(db), throwsA(anything));

      final staged = await db
          .customSelect('SELECT COUNT(*) AS n FROM dive_profiles_inbound')
          .getSingle();
      expect(
        staged.data['n'],
        2,
        reason: 'a failed pack must not discard the only copy of the rows',
      );

      // Repair the table (mirrors a real migration/backstop self-heal) and
      // confirm the next call packs the still-staged rows and empties them.
      await db.customStatement('DROP TABLE dive_profile_series');
      await db.customStatement('''
          CREATE TABLE dive_profile_series (
            id TEXT NOT NULL PRIMARY KEY,
            dive_id TEXT NOT NULL,
            computer_id TEXT,
            source_id TEXT,
            is_primary INTEGER NOT NULL DEFAULT 1,
            sample_count INTEGER NOT NULL,
            start_timestamp INTEGER NOT NULL,
            end_timestamp INTEGER NOT NULL,
            max_depth REAL NOT NULL,
            first_depth REAL NOT NULL,
            last_depth REAL NOT NULL,
            has_deco_type INTEGER NOT NULL DEFAULT 0,
            has_deco_stop INTEGER NOT NULL DEFAULT 0,
            has_positive_ceiling INTEGER NOT NULL DEFAULT 0,
            codec_version INTEGER NOT NULL,
            samples BLOB NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            hlc TEXT
          )
        ''');

      final report = await packStagedLegacyRows(db);
      expect(report.profileSeries, 1);
      final series = await ProfileSeriesRepository().getSeriesForDive('dive-1');
      expect(series.single.samples.map((s) => s.depth), [0.0, 12.0]);
      final after = await db
          .customSelect('SELECT COUNT(*) AS n FROM dive_profiles_inbound')
          .getSingle();
      expect(after.data['n'], 0);
    },
  );
}
