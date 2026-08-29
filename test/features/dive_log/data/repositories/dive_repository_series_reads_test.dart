import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/features/dive_log/data/repositories/dive_repository_impl.dart';
import 'package:submersion/features/dive_log/data/repositories/profile_series_repository.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_sample.dart';

import '../../../../helpers/test_database.dart';

/// The series-first read paths. Fixtures are written through the series
/// repository; the legacy-row fixtures in the neighbouring test files keep
/// covering the fallback branch until plan 2e removes it.
void main() {
  late AppDatabase db;
  late DiveRepository dives;
  late ProfileSeriesRepository series;
  const now = 1750000000000;

  setUp(() async {
    db = await setUpTestDatabase();
    dives = DiveRepository();
    series = ProfileSeriesRepository();
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
    for (final computer in ['comp-1', 'comp-2']) {
      await db
          .into(db.diveComputers)
          .insert(
            DiveComputersCompanion.insert(
              id: computer,
              name: computer,
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
  });

  tearDown(tearDownTestDatabase);

  Future<void> source(String id, String? computerId, {bool primary = false}) =>
      db
          .into(db.diveDataSources)
          .insert(
            DiveDataSourcesCompanion.insert(
              id: id,
              diveId: 'dive-1',
              computerId: Value(computerId),
              isPrimary: Value(primary),
              importedAt: DateTime.fromMillisecondsSinceEpoch(now),
              createdAt: DateTime.fromMillisecondsSinceEpoch(now),
            ),
          );

  test(
    'getDiveProfile returns only primary series, merged by timestamp',
    () async {
      await series.insertSeries(
        diveId: 'dive-1',
        computerId: 'comp-1',
        samples: const [
          ProfileSample(timestamp: 0, depth: 0.0),
          ProfileSample(timestamp: 20, depth: 10.0),
        ],
        now: now,
      );
      await series.insertSeries(
        diveId: 'dive-1',
        computerId: 'comp-2',
        isPrimary: false,
        samples: const [ProfileSample(timestamp: 10, depth: 99.0)],
        now: now,
      );
      final profile = await dives.getDiveProfile('dive-1');
      expect(profile.map((p) => p.timestamp), [0, 20]);
      expect(profile.map((p) => p.depth), [0.0, 10.0]);
    },
  );

  test(
    'getMergedProfile keeps every source and getDiveById stays in step',
    () async {
      await source('src-1', 'comp-1', primary: true);
      await source('src-2', 'comp-2');
      await series.insertSeries(
        diveId: 'dive-1',
        computerId: 'comp-1',
        sourceId: 'src-1',
        samples: const [
          ProfileSample(timestamp: 0, depth: 0.0),
          ProfileSample(timestamp: 20, depth: 10.0),
        ],
        now: now,
      );
      await series.insertSeries(
        diveId: 'dive-1',
        computerId: 'comp-2',
        sourceId: 'src-2',
        isPrimary: false,
        samples: const [ProfileSample(timestamp: 10, depth: 4.0)],
        now: now,
      );
      final merged = await dives.getMergedProfile('dive-1');
      expect(merged.map((p) => p.timestamp), [0, 10, 20]);
      final byId = await dives.getDiveById('dive-1');
      expect(byId!.profile, merged);
      final analysis = await dives.getDiveForAnalysis('dive-1');
      expect(analysis!.profile, merged);
    },
  );

  test(
    'an edit supersedes the demoted original of the primary family',
    () async {
      await source('src-1', 'comp-1', primary: true);
      await source('src-2', 'comp-2');
      await series.insertSeries(
        diveId: 'dive-1',
        computerId: 'comp-1',
        sourceId: 'src-1',
        isPrimary: false,
        samples: const [
          ProfileSample(timestamp: 0, depth: 0.0),
          ProfileSample(timestamp: 10, depth: 30.0),
        ],
        now: now,
      );
      await series.insertSeries(
        diveId: 'dive-1',
        sourceId: 'src-1',
        samples: const [ProfileSample(timestamp: 0, depth: 0.0)],
        now: now,
      );
      await series.insertSeries(
        diveId: 'dive-1',
        computerId: 'comp-2',
        sourceId: 'src-2',
        isPrimary: false,
        samples: const [ProfileSample(timestamp: 5, depth: 7.0)],
        now: now,
      );
      final merged = await dives.getMergedProfile('dive-1');
      // The trimmed original (30 m at t=10) is gone; the other computer stays.
      expect(merged.map((p) => p.depth), [0.0, 7.0]);
      expect((await dives.getDiveById('dive-1'))!.profile, merged);
    },
  );

  test('a demoted null-computer series next to a computer-owned primary is '
      'kept, as the legacy read keeps it', () async {
    await source('src-1', 'comp-1', primary: true);
    await series.insertSeries(
      diveId: 'dive-1',
      computerId: 'comp-1',
      sourceId: 'src-1',
      samples: const [ProfileSample(timestamp: 0, depth: 1.0)],
      now: now,
    );
    await series.insertSeries(
      diveId: 'dive-1',
      sourceId: 'src-1',
      isPrimary: false,
      samples: const [ProfileSample(timestamp: 5, depth: 2.0)],
      now: now,
    );
    final merged = await dives.getMergedProfile('dive-1');
    expect(merged.map((p) => p.depth), [1.0, 2.0]);
  });

  test('series present but none primary: getDiveProfile is empty, '
      'getMergedProfile keeps the demoted series', () async {
    await series.insertSeries(
      diveId: 'dive-1',
      isPrimary: false,
      samples: const [ProfileSample(timestamp: 0, depth: 1.0)],
      now: now,
    );
    await series.insertSeries(
      diveId: 'dive-1',
      isPrimary: false,
      samples: const [ProfileSample(timestamp: 5, depth: 2.0)],
      now: now,
    );
    expect(await dives.getDiveProfile('dive-1'), isEmpty);
    final merged = await dives.getMergedProfile('dive-1');
    expect(merged.map((p) => p.depth), [1.0, 2.0]);
  });

  test('a dive with no series falls back to the legacy rows', () async {
    await db
        .into(db.diveProfiles)
        .insert(
          const DiveProfilesCompanion(
            id: Value('legacy-1'),
            diveId: Value('dive-1'),
            timestamp: Value(5),
            depth: Value(3.0),
          ),
        );
    expect((await dives.getDiveProfile('dive-1')).single.depth, 3.0);
    expect((await dives.getMergedProfile('dive-1')).single.depth, 3.0);
    expect((await dives.getDiveById('dive-1'))!.profile.single.depth, 3.0);
  });

  test('series rows win over legacy rows when both exist', () async {
    await db
        .into(db.diveProfiles)
        .insert(
          const DiveProfilesCompanion(
            id: Value('legacy-1'),
            diveId: Value('dive-1'),
            timestamp: Value(5),
            depth: Value(3.0),
          ),
        );
    await series.insertSeries(
      diveId: 'dive-1',
      samples: const [ProfileSample(timestamp: 0, depth: 9.0)],
      now: now,
    );
    expect((await dives.getDiveProfile('dive-1')).single.depth, 9.0);
  });

  test('a series write ticks the detail and analysis watchers', () async {
    final detail = dives.watchDiveDetailChanges().first;
    final analysis = dives.watchAnalysisInputChanges().first;
    await series.insertSeries(
      diveId: 'dive-1',
      samples: const [ProfileSample(timestamp: 0, depth: 1.0)],
      now: now,
    );
    await expectLater(detail, completes);
    await expectLater(analysis, completes);
  });
}
