import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/features/dive_log/data/repositories/profile_series_repository.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_sample.dart';

import '../../../../helpers/test_database.dart';

/// `diveSegmentCountProvider` asks on every dive-detail open whether a dive
/// can be separated (issue #1504), and the answer is a function of where each
/// series sits on the timeline. `getRowsForDives` would answer it, but it
/// selects whole rows, so it reads every packed sample blob off disk to look
/// at the three scalars beside them. A four hour CCR profile at a two second
/// cadence packs to roughly 150 KB; that does not belong on a UI path.
void main() {
  late AppDatabase db;
  late ProfileSeriesRepository repo;
  const now = 1750000000000;

  setUp(() async {
    db = await setUpTestDatabase();
    repo = ProfileSeriesRepository();
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
        .into(db.diveDataSources)
        .insert(
          DiveDataSourcesCompanion.insert(
            id: 'src-1',
            diveId: 'dive-1',
            importedAt: DateTime.utc(2026, 7, 1),
            createdAt: DateTime.utc(2026, 7, 1),
          ),
        );
  });

  tearDown(tearDownTestDatabase);

  test('getSpansForDive reports each series identity and span', () async {
    await repo.insertSeries(
      diveId: 'dive-1',
      sourceId: 'src-1',
      samples: const [
        ProfileSample(timestamp: 30, depth: 5),
        ProfileSample(timestamp: 900, depth: 18),
      ],
      now: now,
    );
    await repo.insertSeries(
      diveId: 'dive-1',
      isPrimary: false,
      samples: const [
        ProfileSample(timestamp: 1800, depth: 12),
        ProfileSample(timestamp: 2400, depth: 0),
      ],
      now: now,
    );

    final spans = await repo.getSpansForDive('dive-1');

    // Earliest first, and the owning source survives the projection: the
    // segment grouping attributes a series by its sourceId, so dropping that
    // column would make every series look unattributed.
    expect(spans, hasLength(2));
    expect(spans.first.sourceId, 'src-1');
    expect(spans.first.startTimestamp, 30);
    expect(spans.first.endTimestamp, 900);
    expect(spans.last.sourceId, isNull);
    expect(spans.last.startTimestamp, 1800);
    expect(spans.last.endTimestamp, 2400);
  });

  test('getSpansForDive agrees with the full rows it replaces', () async {
    for (final start in [0, 600, 1200]) {
      await repo.insertSeries(
        diveId: 'dive-1',
        sourceId: 'src-1',
        samples: [
          for (var t = start; t < start + 300; t += 30)
            ProfileSample(timestamp: t, depth: 10),
        ],
        now: now,
      );
    }

    final spans = await repo.getSpansForDive('dive-1');
    final rows = await repo.getRowsForDives(['dive-1']);

    // The projection must not drift from the rows: both are read by the same
    // grouping rule, one on the UI path and one inside the separation write.
    expect(spans.map((s) => s.id), rows.map((r) => r.id));
    expect(
      spans.map((s) => (s.startTimestamp, s.endTimestamp)),
      rows.map((r) => (r.startTimestamp, r.endTimestamp)),
    );
    expect(spans.map((s) => s.sourceId), rows.map((r) => r.sourceId));
  });

  test('getSpansForDive is empty for a dive with no series', () async {
    expect(await repo.getSpansForDive('dive-1'), isEmpty);
  });
}
