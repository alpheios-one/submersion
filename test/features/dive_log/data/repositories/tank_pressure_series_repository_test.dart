import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/features/dive_log/data/repositories/tank_pressure_series_repository.dart';
import 'package:submersion/features/dive_log/domain/codecs/tank_pressure_series_codec.dart';

import '../../../../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late TankPressureSeriesRepository repo;
  const now = 1750000000000;

  const samples = [
    TankPressureSample(timestamp: 0, pressure: 200.0),
    TankPressureSample(timestamp: 60, pressure: 190.5),
    TankPressureSample(timestamp: 120, pressure: 181.0),
  ];

  setUp(() async {
    db = await setUpTestDatabase();
    repo = TankPressureSeriesRepository();
    await db
        .into(db.dives)
        .insert(
          const DivesCompanion(
            id: Value('dive-1'),
            diveDateTime: Value(now),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
    await db
        .into(db.diveComputers)
        .insert(
          DiveComputersCompanion.insert(
            id: 'comp-1',
            name: 'Perdix',
            createdAt: now,
            updatedAt: now,
          ),
        );
    for (final tank in ['tank-a', 'tank-b']) {
      await db
          .into(db.diveTanks)
          .insert(DiveTanksCompanion.insert(id: tank, diveId: 'dive-1'));
    }
  });

  tearDown(tearDownTestDatabase);

  test('insertSeries stores the encoded readings and summary', () async {
    final id = await repo.insertSeries(
      diveId: 'dive-1',
      tankId: 'tank-a',
      computerId: 'comp-1',
      samples: samples,
      now: now,
    );
    final row = await (db.select(
      db.tankPressureSeries,
    )..where((t) => t.id.equals(id))).getSingle();
    expect(row.tankId, 'tank-a');
    expect(row.computerId, 'comp-1');
    expect(row.sampleCount, 3);
    expect(row.startTimestamp, 0);
    expect(row.endTimestamp, 120);
    expect(row.hlc, isNotNull);

    final read = await repo.getSeriesForTank('dive-1', 'tank-a');
    expect(read.single.samples, samples);
    expect(read.single.summary.sampleCount, 3);
  });

  test('exact duplicates are dropped and an empty list is refused', () async {
    final id = await repo.insertSeries(
      diveId: 'dive-1',
      tankId: 'tank-a',
      samples: [samples[0], samples[0], samples[1]],
      now: now,
    );
    final read = await repo.getSeriesForTank('dive-1', 'tank-a');
    expect(read.single.id, id);
    expect(read.single.samples, [samples[0], samples[1]]);
    expect(
      () => repo.insertSeries(
        diveId: 'dive-1',
        tankId: 'tank-a',
        samples: const [],
      ),
      throwsArgumentError,
    );
  });

  test('getSeriesForDive orders by tank then start', () async {
    await repo.insertSeries(
      diveId: 'dive-1',
      tankId: 'tank-b',
      samples: samples,
      id: 'b',
      now: now,
    );
    await repo.insertSeries(
      diveId: 'dive-1',
      tankId: 'tank-a',
      samples: samples,
      id: 'a',
      now: now,
    );
    final all = await repo.getSeriesForDive('dive-1');
    expect(all.map((s) => s.id), ['a', 'b']);
  });

  test(
    'deleteForTank and deleteOwnedByComputer tombstone what they remove',
    () async {
      final a = await repo.insertSeries(
        diveId: 'dive-1',
        tankId: 'tank-a',
        computerId: 'comp-1',
        samples: samples,
        now: now,
      );
      final b = await repo.insertSeries(
        diveId: 'dive-1',
        tankId: 'tank-b',
        samples: samples,
        now: now,
      );

      expect(await repo.deleteForTank('dive-1', 'tank-a'), [a]);
      expect((await repo.getSeriesForDive('dive-1')).map((s) => s.id), [b]);

      expect(await repo.deleteOwnedByComputer('dive-1', null), [b]);
      expect(await repo.getSeriesForDive('dive-1'), isEmpty);

      final tombstones =
          await (db.select(db.deletionLog)..where(
                (t) => t.entityType.equals(
                  TankPressureSeriesRepository.entityType,
                ),
              ))
              .get();
      expect(tombstones.map((t) => t.recordId).toSet(), {a, b});
    },
  );

  test('deleteForDive removes every series of the dive', () async {
    await repo.insertSeries(
      diveId: 'dive-1',
      tankId: 'tank-a',
      samples: samples,
    );
    await repo.insertSeries(
      diveId: 'dive-1',
      tankId: 'tank-b',
      samples: samples,
    );
    expect(await repo.deleteForDive('dive-1'), hasLength(2));
    expect(await repo.getSeriesForDive('dive-1'), isEmpty);
  });
}
