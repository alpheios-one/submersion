import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/features/dive_log/domain/models/dive_filter_state.dart';
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

  Future<void> insertDive({
    required String id,
    required DateTime at,
    double? maxDepth,
    int? bottomTimeSeconds,
    double? waterTemp,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db
        .into(db.dives)
        .insert(
          DivesCompanion(
            id: Value(id),
            diveDateTime: Value(at.millisecondsSinceEpoch),
            maxDepth: Value(maxDepth),
            bottomTime: Value(bottomTimeSeconds),
            waterTemp: Value(waterTemp),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
  }

  group('getDepthPerDive', () {
    test('returns one point per dive, ordered by date', () async {
      await insertDive(id: 'b', at: DateTime.utc(2024, 5, 20), maxDepth: 30.0);
      await insertDive(id: 'a', at: DateTime.utc(2024, 5, 10), maxDepth: 18.0);

      final points = await repository.getDepthPerDive();

      expect(points, hasLength(2));
      expect(points[0].value, 18.0);
      expect(points[1].value, 30.0);
      expect(points[0].date.isBefore(points[1].date), isTrue);
    });

    test('does not collapse two dives in the same month', () async {
      await insertDive(id: 'a', at: DateTime.utc(2024, 5, 10), maxDepth: 18.0);
      await insertDive(id: 'b', at: DateTime.utc(2024, 5, 11), maxDepth: 30.0);

      expect(await repository.getDepthPerDive(), hasLength(2));
    });

    test('includes a dive far older than five years', () async {
      // The regression that matters: the old code hardcoded a five-year
      // cutoff, so "lifetime" was unreachable no matter what filter was set.
      final longAgo = DateTime.now().toUtc().subtract(
        const Duration(days: 365 * 8),
      );
      await insertDive(id: 'ancient', at: longAgo, maxDepth: 12.0);

      final points = await repository.getDepthPerDive();

      expect(points, hasLength(1));
      expect(points.single.value, 12.0);
    });

    test('skips dives with no recorded max depth', () async {
      await insertDive(id: 'a', at: DateTime.utc(2024, 5, 10));

      expect(await repository.getDepthPerDive(), isEmpty);
    });

    test('honours a date filter', () async {
      await insertDive(id: 'a', at: DateTime.utc(2020, 5, 10), maxDepth: 18.0);
      await insertDive(id: 'b', at: DateTime.utc(2024, 5, 10), maxDepth: 30.0);

      final points = await repository.getDepthPerDive(
        filter: DiveFilterState(startDate: DateTime.utc(2023, 1, 1)),
      );

      expect(points, hasLength(1));
      expect(points.single.value, 30.0);
    });
  });

  group('getBottomTimePerDive', () {
    test('returns minutes, one point per dive', () async {
      await insertDive(
        id: 'a',
        at: DateTime.utc(2024, 5, 10),
        bottomTimeSeconds: 45 * 60,
      );
      await insertDive(
        id: 'b',
        at: DateTime.utc(2024, 5, 11),
        bottomTimeSeconds: 60 * 60,
      );

      final points = await repository.getBottomTimePerDive();

      expect(points, hasLength(2));
      expect(points[0].value, closeTo(45, 1e-9));
      expect(points[1].value, closeTo(60, 1e-9));
    });

    test('includes a dive far older than five years', () async {
      final longAgo = DateTime.now().toUtc().subtract(
        const Duration(days: 365 * 8),
      );
      await insertDive(id: 'ancient', at: longAgo, bottomTimeSeconds: 30 * 60);

      expect(await repository.getBottomTimePerDive(), hasLength(1));
    });
  });
}
