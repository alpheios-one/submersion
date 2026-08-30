import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/features/dive_log/data/repositories/dive_computer_repository_impl.dart';
import 'package:submersion/features/dive_log/data/repositories/profile_series_repository.dart';
import 'package:submersion/features/dive_log/data/repositories/tank_pressure_series_repository.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_sample.dart';

import '../../../../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late DiveComputerRepository computers;
  late ProfileSeriesRepository series;
  late TankPressureSeriesRepository tankSeries;

  Future<void> insertComputer(String id) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db
        .into(db.diveComputers)
        .insert(
          DiveComputersCompanion(
            id: Value(id),
            name: Value('Computer $id'),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
  }

  setUp(() async {
    db = await setUpTestDatabase();
    computers = DiveComputerRepository();
    series = ProfileSeriesRepository();
    tankSeries = TankPressureSeriesRepository();
    await insertComputer('comp-1');
    await insertComputer('comp-2');
  });

  tearDown(() async {
    await tearDownTestDatabase();
  });

  // isPrimary is passed false on purpose: a dive with no series makes the
  // import primary regardless (the legacy `hasProfiles == 0` rule).
  Future<String> importDive({String computerId = 'comp-1'}) =>
      computers.importProfile(
        computerId: computerId,
        profileStartTime: DateTime(2026, 1, 1, 10),
        points: const [
          ProfilePointData(
            timestamp: 30,
            depth: 10.0,
            pressure: 190.0,
            tankIndex: 0,
          ),
          ProfilePointData(
            timestamp: 0,
            depth: 0.0,
            pressure: 200.0,
            tankIndex: 0,
          ),
        ],
        durationSeconds: 60,
        maxDepth: 10.0,
        isPrimary: false,
        tanks: const [TankData(index: 0, o2Percent: 21.0)],
      );

  test(
    'a first import writes one primary series owned by the computer and its source, and one tank series',
    () async {
      final diveId = await importDive();
      final rows = await series.getSeriesForDive(diveId);
      expect(rows, hasLength(1));
      expect(rows.single.isPrimary, isTrue);
      expect(rows.single.computerId, 'comp-1');
      expect(rows.single.sourceId, isNotNull);
      expect(rows.single.samples.map((s) => s.timestamp), [0, 30]);
      expect(await db.select(db.diveProfiles).get(), isEmpty);
      final tanks = await tankSeries.getSeriesForDive(diveId);
      expect(tanks, hasLength(1));
      expect(tanks.single.computerId, 'comp-1');
      expect(tanks.single.samples.map((s) => s.pressure), [200.0, 190.0]);
      expect(await db.select(db.tankPressureProfiles).get(), isEmpty);
    },
  );

  test(
    'a second import of the same dive and computer does not insert a second series',
    () async {
      final first = await importDive();
      final second = await importDive();
      expect(second, first);
      expect(await series.getSeriesForDive(first), hasLength(1));
      expect(await tankSeries.getSeriesForDive(first), hasLength(1));
    },
  );

  test(
    'setPrimaryProfile flips the flags by computer and writes no tombstone',
    () async {
      final diveId = await importDive();
      final second = await series.insertSeries(
        diveId: diveId,
        computerId: 'comp-2',
        isPrimary: false,
        samples: const [ProfileSample(timestamp: 0, depth: 2.0)],
        now: 1000,
      );
      await computers.setPrimaryProfile(diveId, 'comp-2');
      final rows = await series.getSeriesForDive(diveId);
      expect(rows.firstWhere((s) => s.id == second).isPrimary, isTrue);
      expect(rows.firstWhere((s) => s.id != second).isPrimary, isFalse);
      expect(await db.select(db.deletionLog).get(), isEmpty);
    },
  );

  test(
    'clearSourceAndProfiles deletes the computer profile series and every tank series of the dive',
    () async {
      final diveId = await importDive();
      final imported = (await series.getSeriesForDive(diveId)).single.id;
      final tank = (await tankSeries.getSeriesForDive(diveId)).single.id;
      final edit = await series.insertSeries(
        diveId: diveId,
        samples: const [ProfileSample(timestamp: 0, depth: 9.0)],
        now: 1000,
      );
      await computers.clearSourceAndProfiles(
        diveId: diveId,
        computerId: 'comp-1',
      );
      expect((await series.getSeriesForDive(diveId)).map((s) => s.id), [edit]);
      expect(await tankSeries.getSeriesForDive(diveId), isEmpty);
      final tombstones = await db.select(db.deletionLog).get();
      expect(tombstones.map((t) => t.recordId).toSet(), {imported, tank});
      expect(await db.select(db.diveProfiles).get(), isEmpty);
      expect(await db.select(db.tankPressureProfiles).get(), isEmpty);
    },
  );
}
