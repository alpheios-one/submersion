import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/features/dive_log/data/repositories/dive_repository_impl.dart';
import 'package:submersion/features/dive_log/data/repositories/profile_series_repository.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_sample.dart';

import '../../../../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late DiveRepository dives;
  late ProfileSeriesRepository series;
  const now = 1750000000000;

  setUp(() async {
    db = await setUpTestDatabase();
    dives = DiveRepository();
    series = ProfileSeriesRepository();
    for (final id in ['dive-1', 'dive-2', 'dive-3']) {
      await db
          .into(db.dives)
          .insert(
            DivesCompanion(
              id: Value(id),
              diveDateTime: const Value(now),
              createdAt: const Value(now),
              updatedAt: const Value(now),
            ),
          );
    }
  });

  tearDown(tearDownTestDatabase);

  test('series-backed and legacy-backed dives are both summarised', () async {
    await series.insertSeries(
      diveId: 'dive-1',
      samples: [
        for (var i = 0; i < 300; i++)
          ProfileSample(timestamp: i, depth: i.toDouble()),
      ],
      now: now,
    );
    await db
        .into(db.diveProfiles)
        .insert(
          const DiveProfilesCompanion(
            id: Value('legacy-1'),
            diveId: Value('dive-2'),
            timestamp: Value(7),
            depth: Value(3.0),
          ),
        );
    final summaries = await dives.getBatchProfileSummaries([
      'dive-1',
      'dive-2',
      'dive-3',
    ], maxSamples: 120);
    expect(summaries.keys.toSet(), {'dive-1', 'dive-2'});
    expect(summaries['dive-1'], hasLength(120));
    expect(summaries['dive-1']!.first.timestamp, 0);
    expect(summaries['dive-1']!.last.timestamp, 299);
    expect(summaries['dive-2']!.single.depth, 3.0);
  });

  test('every series of a dive contributes, primary or not', () async {
    await series.insertSeries(
      diveId: 'dive-1',
      samples: const [ProfileSample(timestamp: 0, depth: 1.0)],
      now: now,
    );
    await series.insertSeries(
      diveId: 'dive-1',
      isPrimary: false,
      computerId: null,
      samples: const [ProfileSample(timestamp: 10, depth: 2.0)],
      now: now,
    );
    final summaries = await dives.getBatchProfileSummaries(['dive-1']);
    expect(summaries['dive-1']!.map((p) => p.timestamp), [0, 10]);
  });

  test('an empty id list returns an empty map', () async {
    expect(await dives.getBatchProfileSummaries(const []), isEmpty);
  });
}
