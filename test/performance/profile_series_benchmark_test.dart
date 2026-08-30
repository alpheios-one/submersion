@Tags(['performance'])
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:submersion/core/database/database.dart' hide Tags;
import 'package:submersion/core/services/database_service.dart';
import 'package:submersion/features/dive_log/data/repositories/dive_repository_impl.dart';
import 'package:submersion/features/statistics/data/repositories/statistics_repository.dart';

/// Spec section 10 gates on the synthesized 1,000-dive fixture. Legacy
/// numbers come from the legacy SQL shapes run raw against the
/// pre-migration copy; series numbers from the app's own methods on the
/// migrated copy. Set SUBMERSION_BENCH_FIXTURE to the fixture path
/// (see test/performance/README.md); the test skips without it.
void main() {
  final fixture = Platform.environment['SUBMERSION_BENCH_FIXTURE'];

  test(
    'profile series benchmarks: nothing slower than the legacy shapes',
    () async {
      if (fixture == null) {
        markTestSkipped('SUBMERSION_BENCH_FIXTURE not set');
        return;
      }
      final work = Directory.systemTemp.createTempSync('series-bench');
      final legacyCopy = File('${work.path}/legacy.db')
        ..writeAsBytesSync(File(fixture).readAsBytesSync());
      final migratedCopy = File('${work.path}/migrated.db')
        ..writeAsBytesSync(File(fixture).readAsBytesSync());
      final results = <String, ({Duration legacy, Duration series})>{};

      // Legacy shapes, raw SQL, pre-migration copy.
      final raw = sqlite.sqlite3.open(legacyCopy.path);
      final diveIds = raw
          .select('SELECT id FROM dives ORDER BY dive_date_time DESC LIMIT 50')
          .map((r) => r['id'] as String)
          .toList();
      final legacyHydrate = _time(() {
        for (final id in diveIds) {
          raw.select(
            'SELECT * FROM dive_profiles WHERE dive_id = ? AND is_primary = 1 '
            'ORDER BY timestamp',
            [id],
          );
          raw.select(
            'SELECT * FROM tank_pressure_profiles WHERE dive_id = ? '
            'ORDER BY timestamp',
            [id],
          );
        }
      });
      final legacySummaries = _time(() {
        raw.select(_legacyBatchSummarySql(diveIds.length), diveIds);
      });
      final legacyAscent = _time(() => raw.select(_legacyAscentDescentSql));
      final legacyBuckets = _time(() => raw.select(_legacyTimeAtDepthSql));
      final sizeBefore = legacyCopy.lengthSync();
      raw.close();

      // Migration (the ladder from the fixture's version to 183) plus VACUUM.
      final storedBefore = DatabaseService.getStoredSchemaVersion(
        migratedCopy.path,
      )!;
      final migration = Stopwatch()..start();
      final migrator = AppDatabase(NativeDatabase(migratedCopy));
      await migrator.customSelect('SELECT 1').get();
      migration.stop();
      final vacuum = Stopwatch()..start();
      await migrator.customStatement('VACUUM');
      vacuum.stop();
      await migrator.close();
      final sizeAfter = migratedCopy.lengthSync();

      // Series path through the app, migrated copy.
      final db = AppDatabase(NativeDatabase(migratedCopy));
      DatabaseService.instance.setTestDatabase(db);
      final dives = DiveRepository();
      final stats = StatisticsRepository();
      final seriesHydrate = await _timeAsync(() async {
        for (final id in diveIds) {
          await dives.getDiveById(id);
        }
      });
      final seriesSummaries = await _timeAsync(
        () => dives.getBatchProfileSummaries(diveIds, maxSamples: 200),
      );
      final seriesAscent = await _timeAsync(
        () => stats.getAscentDescentRates(),
      );
      final seriesBuckets = await _timeAsync(
        () => stats.getTimeAtDepthRanges(),
      );
      await db.close();
      DatabaseService.instance.resetForTesting();

      results['per-dive hydrate (50 dives)'] = (
        legacy: legacyHydrate,
        series: seriesHydrate,
      );
      results['batch summaries (50 dives)'] = (
        legacy: legacySummaries,
        series: seriesSummaries,
      );
      results['ascent/descent rates'] = (
        legacy: legacyAscent,
        series: seriesAscent,
      );
      results['time at depth'] = (legacy: legacyBuckets, series: seriesBuckets);

      final table = StringBuffer()
        ..writeln('| metric | legacy | series |')
        ..writeln('|---|---|---|');
      for (final e in results.entries) {
        table.writeln(
          '| ${e.key} | ${e.value.legacy.inMilliseconds} ms | '
          '${e.value.series.inMilliseconds} ms |',
        );
      }
      table
        ..writeln(
          '| migration $storedBefore -> ${AppDatabase.currentSchemaVersion} '
          '| | ${migration.elapsed.inMilliseconds} ms |',
        )
        ..writeln('| VACUUM | | ${vacuum.elapsed.inMilliseconds} ms |')
        ..writeln(
          '| file size | ${sizeBefore ~/ 1024} KB | ${sizeAfter ~/ 1024} KB |',
        );
      // ignore: avoid_print
      print(table);

      for (final e in results.entries) {
        expect(
          e.value.series.inMicroseconds,
          lessThanOrEqualTo((e.value.legacy.inMicroseconds * 1.25).round()),
          reason:
              '${e.key}: series ${e.value.series} vs legacy '
              '${e.value.legacy} (25% tolerance for timer noise)',
        );
      }
      // green after Task 2: the drop (schema 183) has not landed yet, so the
      // migrated copy's ladder still stops at 182 and the legacy tables are
      // still present, keeping the file large.
      expect(
        sizeAfter,
        lessThan(sizeBefore ~/ 2),
        reason: 'the drop plus VACUUM must return most of the file',
      );
      // green after Task 2: schema 183 (the drop) does not exist on this
      // commit, so the fixture's stored version is never below it.
      expect(storedBefore, lessThan(183));
      expect(
        DatabaseService.getStoredSchemaVersion(migratedCopy.path),
        AppDatabase.currentSchemaVersion,
      );
    },
  );
}

Duration _time(void Function() body) {
  final sw = Stopwatch()..start();
  body();
  return sw.elapsed;
}

Future<Duration> _timeAsync(Future<void> Function() body) async {
  final sw = Stopwatch()..start();
  await body();
  return sw.elapsed;
}

String _legacyBatchSummarySql(int n) =>
    'SELECT dive_id, timestamp, depth FROM dive_profiles '
    'WHERE is_primary = 1 AND dive_id IN '
    '(${List.filled(n, '?').join(',')}) ORDER BY dive_id, timestamp';

// The two aggregation queries as they stood before plan 2d, unfiltered scope
// (diver filter and dive filter clauses empty, leaving `WHERE p.is_primary =
// 1` as the only predicate). Copied verbatim from
// `git show 30234a3973e:lib/features/statistics/data/repositories/statistics_repository.dart`
// (getAscentDescentRates at about line 2200, getTimeAtDepthRanges at about
// line 2297), substituting 15 for `_rateWindowSeconds`, 3.0 for
// `_sustainedTransitThreshold` and 4 for `_maxSampleGapFactor`.
const _legacyAscentDescentSql = '''
WITH windows AS (
  SELECT
    p.dive_id AS dive_id,
    p.computer_id AS computer_id,
    p.timestamp / 15 AS window_index,
    AVG(p.depth) AS depth,
    AVG(p.timestamp) AS at
  FROM dive_profiles p
  JOIN dives d ON d.id = p.dive_id
  WHERE p.is_primary = 1
  GROUP BY p.dive_id, p.computer_id, p.timestamp / 15
),
paired AS (
  SELECT
    depth,
    at,
    LAG(depth) OVER w AS prev_depth,
    LAG(at) OVER w AS prev_at
  FROM windows
  WINDOW w AS (PARTITION BY dive_id, computer_id ORDER BY window_index)
),
rates AS (
  SELECT (prev_depth - depth) * 60.0 / (at - prev_at) AS rate
  FROM paired
  WHERE prev_at IS NOT NULL AND at > prev_at
)
SELECT
  AVG(CASE WHEN rate >= 3.0 THEN rate END) AS avg_ascent,
  AVG(CASE WHEN rate <= -3.0 THEN -rate END) AS avg_descent
FROM rates
''';
const _legacyTimeAtDepthSql = '''
WITH samples AS (
  SELECT
    p.dive_id AS dive_id,
    p.computer_id AS computer_id,
    p.id AS sample_id,
    p.timestamp AS at,
    p.depth AS depth
  FROM dive_profiles p
  JOIN dives d ON d.id = p.dive_id
  WHERE p.is_primary = 1
),
cadence AS (
  SELECT
    dive_id,
    computer_id,
    (MAX(at) - MIN(at)) * 4 / (COUNT(*) - 1.0)
      AS max_interval
  FROM samples
  GROUP BY dive_id, computer_id
  HAVING COUNT(*) > 1
),
intervals AS (
  SELECT
    dive_id,
    computer_id,
    depth,
    LEAD(at) OVER w - at AS seconds
  FROM samples
  WINDOW w AS (
    PARTITION BY dive_id, computer_id ORDER BY at, sample_id
  )
)
SELECT
  CASE
    WHEN i.depth < 10 THEN 0
    WHEN i.depth < 20 THEN 10
    WHEN i.depth < 30 THEN 20
    WHEN i.depth < 40 THEN 30
    ELSE 40
  END AS bucket_lo,
  SUM(MIN(i.seconds * 1.0, c.max_interval)) AS seconds
FROM intervals i
JOIN cadence c
  ON c.dive_id = i.dive_id AND c.computer_id IS i.computer_id
WHERE i.seconds > 0
GROUP BY bucket_lo
ORDER BY bucket_lo
''';
