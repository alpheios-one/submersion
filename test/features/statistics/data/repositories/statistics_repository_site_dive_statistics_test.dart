import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/features/statistics/data/repositories/statistics_repository.dart';

import '../../../../helpers/test_database.dart';

void main() {
  late StatisticsRepository repository;
  late AppDatabase db;

  setUp(() async {
    db = await setUpTestDatabase();
    repository = StatisticsRepository();
  });

  tearDown(() async {
    await tearDownTestDatabase();
  });

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<String> insertSite({String? id, String? name}) async {
    final siteId = id ?? 'site-${DateTime.now().microsecondsSinceEpoch}';
    await db
        .into(db.diveSites)
        .insert(
          DiveSitesCompanion.insert(
            id: siteId,
            name: name ?? 'Test Site',
            createdAt: 0,
            updatedAt: 0,
          ),
        );
    return siteId;
  }

  Future<String> insertDive({
    String? id,
    required String siteId,
    String? diverId,
    required DateTime diveDateTime,
    double? maxDepth,
    int? runtime,
    int? bottomTime,
  }) async {
    final diveId = id ?? 'dive-${DateTime.now().microsecondsSinceEpoch}';
    final now = DateTime.now().millisecondsSinceEpoch;
    await db
        .into(db.dives)
        .insert(
          DivesCompanion(
            id: Value(diveId),
            diverId: Value(diverId),
            siteId: Value(siteId),
            diveDateTime: Value(diveDateTime.millisecondsSinceEpoch),
            maxDepth: Value(maxDepth),
            runtime: Value(runtime),
            bottomTime: Value(bottomTime),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
    return diveId;
  }

  group('getSiteDiveStatistics', () {
    test(
      'returns diveCount 0 and null fields when site has no dives',
      () async {
        final siteId = await insertSite();

        final stats = await repository.getSiteDiveStatistics(siteId: siteId);

        expect(stats.diveCount, equals(0));
        expect(stats.hasData, isFalse);
        expect(stats.maxDepthReached, isNull);
        expect(stats.minDepthReached, isNull);
        expect(stats.longestDiveSeconds, isNull);
        expect(stats.averageDurationSeconds, isNull);
        expect(stats.firstDiveAt, isNull);
        expect(stats.lastDiveAt, isNull);
      },
    );

    test('aggregates a single dive', () async {
      final siteId = await insertSite();
      final diveDate = DateTime(2026, 3, 10);
      await insertDive(
        siteId: siteId,
        diveDateTime: diveDate,
        maxDepth: 18.5,
        runtime: 2400,
      );

      final stats = await repository.getSiteDiveStatistics(siteId: siteId);

      expect(stats.diveCount, equals(1));
      expect(stats.hasData, isTrue);
      expect(stats.maxDepthReached, equals(18.5));
      expect(stats.minDepthReached, equals(18.5));
      expect(stats.longestDiveSeconds, equals(2400));
      expect(stats.averageDurationSeconds, equals(2400.0));
      expect(stats.firstDiveAt, equals(diveDate));
      expect(stats.lastDiveAt, equals(diveDate));
    });

    test(
      'aggregates depth range, duration, and date range across multiple dives',
      () async {
        final siteId = await insertSite();
        final earliest = DateTime(2025, 1, 5);
        final middle = DateTime(2025, 6, 15);
        final latest = DateTime(2026, 2, 20);

        await insertDive(
          id: 'dive-1',
          siteId: siteId,
          diveDateTime: middle,
          maxDepth: 20,
          runtime: 3000,
        );
        await insertDive(
          id: 'dive-2',
          siteId: siteId,
          diveDateTime: earliest,
          maxDepth: 12,
          runtime: 1800,
        );
        await insertDive(
          id: 'dive-3',
          siteId: siteId,
          diveDateTime: latest,
          maxDepth: 30,
          runtime: 2400,
        );

        final stats = await repository.getSiteDiveStatistics(siteId: siteId);

        expect(stats.diveCount, equals(3));
        expect(stats.maxDepthReached, equals(30));
        expect(stats.minDepthReached, equals(12));
        expect(stats.longestDiveSeconds, equals(3000));
        expect(stats.averageDurationSeconds, equals((3000 + 1800 + 2400) / 3));
        expect(stats.firstDiveAt, equals(earliest));
        expect(stats.lastDiveAt, equals(latest));
      },
    );

    test(
      'excludes dives without a depth from the depth range but still counts them',
      () async {
        final siteId = await insertSite();
        await insertDive(
          id: 'dive-with-depth',
          siteId: siteId,
          diveDateTime: DateTime(2026, 1, 1),
          maxDepth: 15,
          runtime: 1800,
        );
        await insertDive(
          id: 'dive-no-depth',
          siteId: siteId,
          diveDateTime: DateTime(2026, 1, 2),
          runtime: 1800,
        );

        final stats = await repository.getSiteDiveStatistics(siteId: siteId);

        expect(stats.diveCount, equals(2));
        expect(stats.maxDepthReached, equals(15));
        expect(stats.minDepthReached, equals(15));
      },
    );

    test(
      'excludes dives with neither runtime nor bottom time from the duration '
      'stats but still counts them',
      () async {
        final siteId = await insertSite();
        await insertDive(
          id: 'dive-with-duration',
          siteId: siteId,
          diveDateTime: DateTime(2026, 1, 1),
          maxDepth: 15,
          runtime: 1800,
        );
        await insertDive(
          id: 'dive-no-duration',
          siteId: siteId,
          diveDateTime: DateTime(2026, 1, 2),
          maxDepth: 16,
        );

        final stats = await repository.getSiteDiveStatistics(siteId: siteId);

        expect(stats.diveCount, equals(2));
        expect(stats.longestDiveSeconds, equals(1800));
        expect(stats.averageDurationSeconds, equals(1800.0));
      },
    );

    test('falls back to bottom time when runtime is null', () async {
      final siteId = await insertSite();
      await insertDive(
        siteId: siteId,
        diveDateTime: DateTime(2026, 1, 1),
        bottomTime: 2100,
      );

      final stats = await repository.getSiteDiveStatistics(siteId: siteId);

      expect(stats.longestDiveSeconds, equals(2100));
      expect(stats.averageDurationSeconds, equals(2100.0));
    });

    test(
      'filters dives by diverId, excluding another diver\'s dives',
      () async {
        final siteId = await insertSite();
        await insertDive(
          id: 'dive-diver-a',
          siteId: siteId,
          diverId: 'diver-a',
          diveDateTime: DateTime(2026, 1, 1),
          maxDepth: 10,
          runtime: 1200,
        );
        await insertDive(
          id: 'dive-diver-b',
          siteId: siteId,
          diverId: 'diver-b',
          diveDateTime: DateTime(2026, 1, 2),
          maxDepth: 40,
          runtime: 3600,
        );

        final stats = await repository.getSiteDiveStatistics(
          siteId: siteId,
          diverId: 'diver-a',
        );

        expect(stats.diveCount, equals(1));
        expect(stats.maxDepthReached, equals(10));
        expect(stats.longestDiveSeconds, equals(1200));
      },
    );

    test('does not include dives logged at a different site', () async {
      final siteId = await insertSite(id: 'site-a');
      final otherSiteId = await insertSite(id: 'site-b');
      await insertDive(
        siteId: siteId,
        diveDateTime: DateTime(2026, 1, 1),
        maxDepth: 10,
        runtime: 1200,
      );
      await insertDive(
        siteId: otherSiteId,
        diveDateTime: DateTime(2026, 1, 2),
        maxDepth: 40,
        runtime: 3600,
      );

      final stats = await repository.getSiteDiveStatistics(siteId: siteId);

      expect(stats.diveCount, equals(1));
      expect(stats.maxDepthReached, equals(10));
    });
  });
}
