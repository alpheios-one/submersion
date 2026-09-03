import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/features/dive_log/data/repositories/dive_repository_impl.dart';
import 'package:submersion/features/dive_log/data/repositories/profile_series_repository.dart';
import 'package:submersion/features/dive_log/data/repositories/tank_pressure_series_repository.dart';
import 'package:submersion/features/dive_log/data/services/dive_merge_service.dart';
import 'package:submersion/features/dive_log/data/services/dive_uncombine_service.dart';
import 'package:submersion/features/dive_log/domain/codecs/tank_pressure_series_codec.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart'
    as domain;

import '../../../../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late DiveRepository diveRepo;
  late DiveMergeService merge;
  late DiveUncombineService service;
  late ProfileSeriesRepository profileSeries;
  late TankPressureSeriesRepository tankSeries;

  setUp(() async {
    db = await setUpTestDatabase();
    await db.customStatement('PRAGMA foreign_keys = OFF');
    diveRepo = DiveRepository();
    merge = DiveMergeService(diveRepo);
    service = DiveUncombineService(diveRepo);
    profileSeries = ProfileSeriesRepository();
    tankSeries = TankPressureSeriesRepository();
  });

  tearDown(() async {
    await tearDownTestDatabase();
  });

  /// Seeds one importable dive: a tank, a sparse 3-sample profile, a tank
  /// pressure series, a gas switch, one imported event, and the
  /// `dive_data_sources` row an import writes.
  ///
  /// [computerId] is stamped onto the profile series the way a real download
  /// does, by re-inserting what `createDive` wrote: the domain
  /// DiveProfilePoint carries no computerId, so createDive cannot set one.
  /// FK enforcement is off in this suite, so no `dive_computers` row is
  /// needed.
  Future<void> seedDive(
    String id, {
    required DateTime entry,
    int runtimeMin = 30,
    double depth = 10,
    String? computerId,
    String? siteId,
    bool sourceCarriesSummary = true,
  }) async {
    await diveRepo.createDive(
      domain.Dive(
        id: id,
        diverId: 'diver1',
        dateTime: entry,
        entryTime: entry,
        runtime: Duration(minutes: runtimeMin),
        maxDepth: depth,
        tanks: [domain.DiveTank(id: 'tank-$id', volume: 11.1)],
        profile: [
          const domain.DiveProfilePoint(timestamp: 0, depth: 0),
          domain.DiveProfilePoint(timestamp: runtimeMin * 30, depth: depth),
          domain.DiveProfilePoint(timestamp: runtimeMin * 60, depth: 0),
        ],
      ),
    );
    if (siteId != null) {
      await (db.update(db.dives)..where((t) => t.id.equals(id))).write(
        DivesCompanion(siteId: Value(siteId)),
      );
    }
    if (computerId != null) {
      final created = await profileSeries.getSeriesForDive(id);
      await profileSeries.deleteForDive(id);
      for (final s in created) {
        await profileSeries.insertSeries(
          diveId: id,
          computerId: computerId,
          sourceId: s.sourceId,
          isPrimary: s.isPrimary,
          samples: s.samples,
          now: 0,
        );
      }
    }
    await db
        .into(db.diveProfileEvents)
        .insert(
          DiveProfileEventsCompanion.insert(
            id: 'event-$id',
            diveId: id,
            timestamp: 60,
            eventType: 'gaschange',
            createdAt: 0,
          ).copyWith(tankId: Value('tank-$id')),
        );
    await db
        .into(db.gasSwitches)
        .insert(
          GasSwitchesCompanion.insert(
            id: 'switch-$id',
            diveId: id,
            timestamp: 60,
            tankId: 'tank-$id',
            createdAt: 0,
          ),
        );
    await tankSeries.insertSeries(
      diveId: id,
      tankId: 'tank-$id',
      samples: const [TankPressureSample(timestamp: 60, pressure: 180.0)],
      id: 'tp-$id',
      now: 0,
    );
    await db
        .into(db.diveDataSources)
        .insert(
          DiveDataSourcesCompanion.insert(
            id: 'src-$id',
            diveId: id,
            importedAt: DateTime.utc(2026, 7, 1),
            createdAt: DateTime.utc(2026, 7, 1),
          ).copyWith(
            isPrimary: const Value(true),
            computerId: Value(computerId),
            maxDepth: Value(sourceCarriesSummary ? depth : null),
            sourceFileName: Value('$id.uddf'),
          ),
        );
  }

  Future<String> mergeTwoImports({String? siteId}) async {
    await seedDive('a', entry: DateTime.utc(2026, 7, 1, 9), siteId: siteId);
    await seedDive(
      'b',
      entry: DateTime.utc(2026, 7, 1, 10),
      depth: 20,
      runtimeMin: 20,
      siteId: siteId,
    );
    final outcome = await merge.apply(['a', 'b']);
    return outcome.mergedDive.id;
  }

  group('plan', () {
    test('a dive that was never combined reads as one segment', () async {
      await seedDive('solo', entry: DateTime.utc(2026, 7, 1, 9));

      expect(await service.plan('solo'), hasLength(1));
    });

    test('a dive with no provenance rows reads as no segments', () async {
      await seedDive('solo', entry: DateTime.utc(2026, 7, 1, 9));
      await db.delete(db.diveDataSources).go();

      expect(await service.plan('solo'), isEmpty);
    });

    test('two combined file imports read as two segments', () async {
      // The repro of issue #1504: neither import carries a computerId, so
      // both carried rows land on merge slot 0 and collapse to a single
      // display source, which is what hid Split.
      final mergedId = await mergeTwoImports();
      expect(await diveRepo.getDataSources(mergedId), hasLength(1));

      final segments = await service.plan(mergedId);
      expect(segments, hasLength(2));
      expect(segments.first.sourceIds, hasLength(1));
      expect(segments.last.sourceIds, hasLength(1));
      expect(segments.first.startSeconds, 0);
      expect(segments.last.startSeconds, 3600);
    });

    test(
      'two consolidated computers reading one dive stay one segment',
      () async {
        await seedDive(
          'a',
          entry: DateTime.utc(2026, 7, 1, 9),
          computerId: 'c1',
        );
        await db
            .into(db.diveDataSources)
            .insert(
              DiveDataSourcesCompanion.insert(
                id: 'src-a2',
                diveId: 'a',
                importedAt: DateTime.utc(2026, 7, 1),
                createdAt: DateTime.utc(2026, 7, 2),
              ).copyWith(computerId: const Value('c2')),
            );
        // The second computer's own recording of the same minutes.
        await profileSeries.insertSeries(
          diveId: 'a',
          computerId: 'c2',
          sourceId: 'src-a2',
          isPrimary: false,
          samples: [
            for (final s in (await profileSeries.getSeriesForDive(
              'a',
            )).first.samples)
              s,
          ],
          now: 0,
        );

        expect(await service.plan('a'), hasLength(1));
      },
    );
  });

  group('separate', () {
    test('summarises each restored dive from its own samples', () async {
      // backfillPrimaryDataSource mints a provenance row from the dive it
      // found, so a legacy dive with no bottom_time carries none here. The
      // fallback has to be the segment's own profile: taking the combined
      // dive's aggregate gave a 20 minute half the whole combine's numbers.
      await seedDive(
        'a',
        entry: DateTime.utc(2026, 7, 1, 9),
        sourceCarriesSummary: false,
      );
      await seedDive(
        'b',
        entry: DateTime.utc(2026, 7, 1, 10),
        depth: 20,
        runtimeMin: 20,
        sourceCarriesSummary: false,
      );
      final mergedId = (await merge.apply(['a', 'b'])).mergedDive.id;

      final restoredId = (await service.separate(diveId: mergedId)).single;

      final dives = await db.select(db.dives).get();
      final restored = dives.firstWhere((d) => d.id == restoredId);
      final kept = dives.firstWhere((d) => d.id == mergedId);
      // b: samples 0/600/1200 at depths 0/20/0, so the last sample at or
      // below the 6.6 m threshold sits at 600 s.
      expect(restored.maxDepth, 20);
      expect(restored.bottomTime, 600);
      // a: samples 0/900/1800 at depths 0/10/0, threshold 6 m.
      expect(kept.maxDepth, 10);
      expect(kept.bottomTime, 900);
    });

    test('refuses a dive that reads as one segment', () async {
      await seedDive('solo', entry: DateTime.utc(2026, 7, 1, 9));

      expect(
        () => service.separate(diveId: 'solo'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('restores the combined imports as two dives', () async {
      final mergedId = await mergeTwoImports();
      // A site the user assigned to the combined dive: both halves happened
      // in one place, so a restored half inherits it.
      await (db.update(db.dives)..where((t) => t.id.equals(mergedId))).write(
        const DivesCompanion(siteId: Value('site-1')),
      );

      final newIds = await service.separate(diveId: mergedId);

      expect(newIds, hasLength(1));
      final restoredId = newIds.single;
      final dives = await db.select(db.dives).get();
      expect(dives.map((d) => d.id).toSet(), {mergedId, restoredId});

      // Each dive keeps exactly one provenance row, and the restored one is
      // primary again with its own file name.
      final keptSources = await diveRepo.getDataSources(mergedId);
      final restoredSources = await diveRepo.getDataSources(restoredId);
      expect(keptSources, hasLength(1));
      expect(restoredSources, hasLength(1));
      expect(keptSources.single.sourceFileName, 'a.uddf');
      expect(restoredSources.single.sourceFileName, 'b.uddf');
      expect(restoredSources.single.isPrimary, isTrue);

      // The restored dive's profile is re-based to its own zero, and the
      // merge's surface fill is gone from both.
      final restoredSeries = await profileSeries.getSeriesForDive(restoredId);
      expect(
        [for (final s in restoredSeries) ...s.samples.map((p) => p.timestamp)],
        [0, 600, 1200],
      );
      final keptSeries = await profileSeries.getSeriesForDive(mergedId);
      expect(
        [for (final s in keptSeries) ...s.samples.map((p) => p.timestamp)],
        [0, 900, 1800],
      );

      // Both restored dives are readable: a dive with no primary series has
      // no profile at all (#1149).
      expect(await profileSeries.hasPrimarySeries(restoredId), isTrue);
      expect(await profileSeries.hasPrimarySeries(mergedId), isTrue);

      // Summary scalars come from each half's own provenance row.
      final restored = dives.firstWhere((d) => d.id == restoredId);
      expect(restored.maxDepth, 20);
      expect(restored.diveNumber, isNull);
      expect(restored.siteId, 'site-1');
      expect(
        DateTime.fromMillisecondsSinceEpoch(restored.diveDateTime, isUtc: true),
        DateTime.utc(2026, 7, 1, 10),
      );
    });

    test('drops the surface markers the merge wrote at the gap', () async {
      final mergedId = await mergeTwoImports();

      final newIds = await service.separate(diveId: mergedId);

      final events = await db.select(db.diveProfileEvents).get();
      expect(
        events.where((e) => e.eventType == 'surface' && e.source == 'app'),
        isEmpty,
      );
      // The imported events survive, re-based onto their own dive.
      final restoredEvents = events.where((e) => e.diveId == newIds.single);
      expect(restoredEvents.map((e) => e.timestamp), [60]);
      expect(
        events.where((e) => e.diveId == mergedId).map((e) => e.timestamp),
        [60],
      );
    });

    test('moves tank pressures and gas switches onto cloned tanks', () async {
      final mergedId = await mergeTwoImports();

      final restoredId = (await service.separate(diveId: mergedId)).single;

      final restoredPressures = await tankSeries.getSeriesForDive(restoredId);
      expect(restoredPressures, hasLength(1));
      expect(restoredPressures.single.samples.single.timestamp, 60);
      final restoredTanks = await (db.select(
        db.diveTanks,
      )..where((t) => t.diveId.equals(restoredId))).get();
      expect(restoredTanks, hasLength(1));
      expect(restoredPressures.single.tankId, restoredTanks.single.id);

      final restoredSwitches = await (db.select(
        db.gasSwitches,
      )..where((t) => t.diveId.equals(restoredId))).get();
      expect(restoredSwitches, hasLength(1));
      expect(restoredSwitches.single.timestamp, 60);
      expect(restoredSwitches.single.tankId, restoredTanks.single.id);

      // The original keeps its own, untouched.
      expect(await tankSeries.getSeriesForDive(mergedId), hasLength(1));
    });

    test('tombstones every row it moves off the surviving dive', () async {
      final mergedId = await mergeTwoImports();

      await service.separate(diveId: mergedId);

      final logged = await db.select(db.deletionLog).get();
      final byType = <String, int>{};
      for (final row in logged) {
        byType[row.entityType] = (byType[row.entityType] ?? 0) + 1;
      }
      // The merged dive survives, so peers that already pulled these rows
      // would keep upsert copies of them forever without a tombstone.
      expect(byType['diveDataSources'], greaterThanOrEqualTo(1));
      expect(byType['diveProfileEvents'], greaterThanOrEqualTo(3));
      expect(byType['gasSwitches'], greaterThanOrEqualTo(1));
      expect(byType['diveProfileSeries'], greaterThanOrEqualTo(2));
      expect(byType['tankPressureSeries'], greaterThanOrEqualTo(1));
    });

    test('un-nests a combine of a combine into three dives', () async {
      final mergedId = await mergeTwoImports();
      await seedDive(
        'c',
        entry: DateTime.utc(2026, 7, 1, 11),
        depth: 15,
        runtimeMin: 10,
      );
      final nestedId = (await merge.apply([mergedId, 'c'])).mergedDive.id;

      final newIds = await service.separate(diveId: nestedId);

      expect(newIds, hasLength(2));
      final dives = await db.select(db.dives).get();
      expect(dives, hasLength(3));
      for (final dive in dives) {
        expect(await diveRepo.getDataSources(dive.id), hasLength(1));
      }
      // Every dive is back on its own zero-based timeline, with none of the
      // fill the two merges synthesized. The first merge's fill lives in the
      // FIRST segment's series, not the one adjacent to the second gap, so a
      // span read straight off the summary columns would have swallowed
      // every later segment into it.
      expect(
        [
          for (final dive in dives)
            [
              for (final s in await profileSeries.getSeriesForDive(dive.id))
                ...s.samples.map((p) => p.timestamp),
            ],
        ],
        containsAll([
          [0, 900, 1800],
          [0, 600, 1200],
          [0, 300, 600],
        ]),
      );
    });

    test(
      'separates two computers that were consolidated then combined',
      () async {
        // Both halves carry a computerId, so the display never collapsed them
        // and per-source Split was offered -- but Split would have moved one
        // computer's whole recording, not one half of the dive.
        await seedDive(
          'a',
          entry: DateTime.utc(2026, 7, 1, 9),
          computerId: 'c1',
        );
        await seedDive(
          'b',
          entry: DateTime.utc(2026, 7, 1, 10),
          runtimeMin: 20,
          depth: 20,
          computerId: 'c1',
        );
        final mergedId = (await merge.apply(['a', 'b'])).mergedDive.id;
        expect(await diveRepo.getDataSources(mergedId), hasLength(1));

        final restoredId = (await service.separate(diveId: mergedId)).single;

        expect(
          [
            for (final s in await profileSeries.getSeriesForDive(restoredId))
              ...s.samples.map((p) => p.timestamp),
          ],
          [0, 600, 1200],
        );
        final restoredSources = await diveRepo.getDataSources(restoredId);
        expect(restoredSources.single.computerId, 'c1');
      },
    );
  });
}
