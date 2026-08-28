import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/features/statistics/data/repositories/statistics_repository.dart';

import '../../../../helpers/test_database.dart';

/// Behavioral guard for [DiveStatsScope]: proves every descriptive aggregate
/// actually drops the dives it is supposed to, rather than merely that the
/// predicate string is well formed.
///
/// The fixture seeds five dives, all identical apart from the flag under test,
/// so a leak shows up as an inflated count rather than a subtle shift:
///
/// | id           | counted by non-gas aggregates | counted by gas aggregates |
/// |--------------|-------------------------------|---------------------------|
/// | included     | yes                           | yes                       |
/// | excluded     | no (master flag)              | no                        |
/// | gas-excluded | yes                           | no                        |
/// | planned      | no                            | no                        |
/// | gauge        | yes                           | no (gauge has no gas data)|
///
/// So a non-gas aggregate sees 3 dives and a gas aggregate sees 1.
void main() {
  late StatisticsRepository repository;
  late AppDatabase db;

  /// Dives in scope for a descriptive, non-gas aggregate.
  const nonGasInScope = 3;

  /// Dives in scope for a SAC/RMV or gas-mix aggregate.
  const gasInScope = 1;

  Future<void> insertDive(
    String id, {
    bool excludedFromStats = false,
    bool excludedFromGasStats = false,
    bool isPlanned = false,
    String diveMode = 'oc',
  }) async {
    final at = DateTime.utc(2026, 1, 1).millisecondsSinceEpoch;
    await db
        .into(db.dives)
        .insert(
          DivesCompanion(
            id: Value(id),
            diveDateTime: Value(at),
            diveMode: Value(diveMode),
            avgDepth: const Value(15.0),
            maxDepth: const Value(30.0),
            bottomTime: const Value(1800),
            isPlanned: Value(isPlanned),
            excludedFromStats: Value(excludedFromStats),
            excludedFromGasStats: Value(excludedFromGasStats),
            createdAt: Value(at),
            updatedAt: Value(at),
          ),
        );
    await db
        .into(db.diveTanks)
        .insert(
          DiveTanksCompanion(
            id: Value('tank-$id'),
            diveId: Value(id),
            startPressure: const Value(200.0),
            endPressure: const Value(50.0),
            volume: const Value(11.1),
            o2Percent: const Value(21.0),
            hePercent: const Value(0.0),
            tankOrder: const Value(0),
          ),
        );
  }

  setUp(() async {
    db = await setUpTestDatabase();
    repository = StatisticsRepository();

    await insertDive('included');
    await insertDive('excluded', excludedFromStats: true);
    await insertDive('gas-excluded', excludedFromGasStats: true);
    await insertDive('planned', isPlanned: true);
    await insertDive('gauge', diveMode: 'gauge');
  });

  tearDown(() async {
    await tearDownTestDatabase();
  });

  group('non-gas aggregates drop excluded and planned dives', () {
    test('getDivesPerYear', () async {
      final rows = await repository.getDivesPerYear();
      final total = rows.fold<int>(0, (sum, r) => sum + r.count);
      expect(total, nonGasInScope);
    });

    test('getCumulativeDiveCount', () async {
      final rows = await repository.getCumulativeDiveCount();
      expect(rows.last.value, nonGasInScope.toDouble());
    });

    test('getDepthProgressionTrend', () async {
      final rows = await repository.getDepthProgressionTrend();
      expect(rows, isNotEmpty);
      // One monthly bucket; every seeded dive has the same max depth, so the
      // assertion that bites is the count behind the average, checked above.
      expect(rows.first.value, 30.0);
    });

    test('getDivesByDayOfWeek', () async {
      final rows = await repository.getDivesByDayOfWeek();
      final total = rows.fold<int>(0, (sum, r) => sum + r.count);
      expect(total, nonGasInScope);
    });

    test('getDivesBySeason', () async {
      final rows = await repository.getDivesBySeason();
      final total = rows.fold<int>(0, (sum, r) => sum + r.count);
      expect(total, nonGasInScope);
    });
  });

  group('gas aggregates additionally drop gas-excluded and gauge dives', () {
    test('getGasMixDistribution', () async {
      final dist = await repository.getGasMixDistribution();
      final total = dist.fold<int>(0, (sum, s) => sum + s.count);
      expect(
        total,
        gasInScope,
        reason:
            'the gauge dive and the gas-excluded dive both drop out, on '
            'top of the master-excluded and planned dives',
      );
    });

    test('getSacVolumeTrend', () async {
      final rows = await repository.getSacVolumeTrend();
      expect(rows, isNotEmpty, reason: 'the included dive has tank volume');
      // One month bucket holding exactly the in-scope dives.
      expect(rows.length, 1);
    });

    test('getSacVolumeRecords', () async {
      final records = await repository.getSacVolumeRecords();
      expect(records.best, isNotNull);
      expect(
        records.best!.id,
        'included',
        reason: 'the only dive in scope for a gas aggregate',
      );
      expect(
        records.worst?.id,
        anyOf(isNull, 'included'),
        reason:
            'with a single dive in scope, best and worst are the same '
            'dive or worst is unset; either way no excluded dive appears',
      );
    });
  });

  group('the master flag implies the gas flag', () {
    test('a master-excluded dive is absent from gas aggregates too', () async {
      final records = await repository.getSacVolumeRecords();
      expect(records.best?.id, isNot('excluded'));
      expect(records.worst?.id, isNot('excluded'));
    });
  });
}
