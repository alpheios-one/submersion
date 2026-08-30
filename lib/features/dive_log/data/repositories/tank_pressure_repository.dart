import 'package:drift/drift.dart';

import 'package:submersion/core/data/repositories/sync_repository.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/core/services/database_service.dart';
import 'package:submersion/core/services/sync/sync_event_bus.dart';
import 'package:submersion/features/dive_log/data/repositories/tank_pressure_series_repository.dart';
import 'package:submersion/features/dive_log/domain/codecs/tank_pressure_series_codec.dart'
    show TankPressureSample;
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_log/domain/services/profile_series_merge.dart';

/// Repository for managing per-tank time-series pressure data
///
/// This repository handles storage and retrieval of pressure readings
/// from AI transmitters for multi-tank dives.
class TankPressureRepository {
  AppDatabase get _db => DatabaseService.instance.database;
  final SyncRepository _syncRepository = SyncRepository();
  final TankPressureSeriesRepository _tankSeries =
      TankPressureSeriesRepository();

  /// Get all tank pressure data for a dive, grouped by tank ID
  ///
  /// Returns a map where keys are tank IDs and values are lists of
  /// pressure points sorted by timestamp. Series-first: a dive with tank
  /// pressure series uses those; a dive with none falls back to the legacy
  /// `tank_pressure_profiles` rows.
  Future<Map<String, List<TankPressurePoint>>> getTankPressuresForDive(
    String diveId,
  ) async {
    final series = await _tankSeries.getSeriesForDive(diveId);
    if (series.isEmpty) return _getTankPressuresForDiveLegacy(diveId);
    final byTank = <String, List<dynamic>>{};
    for (final s in series) {
      byTank.putIfAbsent(s.tankId, () => []).add(s);
    }
    final result = <String, List<TankPressurePoint>>{};
    for (final entry in byTank.entries) {
      result[entry.key] = mergeTankSeriesPoints(entry.value.cast());
    }
    return result;
  }

  Future<Map<String, List<TankPressurePoint>>> _getTankPressuresForDiveLegacy(
    String diveId,
  ) async {
    final rows =
        await (_db.select(_db.tankPressureProfiles)
              ..where((t) => t.diveId.equals(diveId))
              ..orderBy([(t) => OrderingTerm.asc(t.timestamp)]))
            .get();

    final result = <String, List<TankPressurePoint>>{};
    for (final row in rows) {
      result
          .putIfAbsent(row.tankId, () => [])
          .add(
            TankPressurePoint(
              id: row.id,
              tankId: row.tankId,
              timestamp: row.timestamp,
              pressure: row.pressure,
            ),
          );
    }

    return result;
  }

  /// Get pressure data for a specific tank. Series-first: falls back to the
  /// legacy rows when the tank has no series.
  ///
  /// This read gates on the TANK's series while [getTankPressuresForDive]
  /// gates on the dive's; the two can only disagree for a tank the packer
  /// skipped as an orphan (no `dive_tanks` parent), which nothing renders.
  Future<List<TankPressurePoint>> getPressuresForTank(
    String diveId,
    String tankId,
  ) async {
    final series = await _tankSeries.getSeriesForTank(diveId, tankId);
    if (series.isEmpty) return _getPressuresForTankLegacy(diveId, tankId);
    return mergeTankSeriesPoints(series);
  }

  Future<List<TankPressurePoint>> _getPressuresForTankLegacy(
    String diveId,
    String tankId,
  ) async {
    final rows =
        await (_db.select(_db.tankPressureProfiles)
              ..where((t) => t.diveId.equals(diveId) & t.tankId.equals(tankId))
              ..orderBy([(t) => OrderingTerm.asc(t.timestamp)]))
            .get();

    return rows
        .map(
          (row) => TankPressurePoint(
            id: row.id,
            tankId: row.tankId,
            timestamp: row.timestamp,
            pressure: row.pressure,
          ),
        )
        .toList();
  }

  /// Bulk insert tank pressure data for a dive
  ///
  /// [pressuresByTank] maps tank IDs to lists of (timestamp, pressure) tuples
  /// Uses batch insert for performance - no individual sync records needed
  /// since parent dive sync covers all child data.
  Future<void> insertTankPressures(
    String diveId,
    Map<String, List<({int timestamp, double pressure})>> pressuresByTank,
  ) async {
    if (pressuresByTank.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final entry in pressuresByTank.entries) {
      if (entry.value.isEmpty) continue;
      await _tankSeries.insertSeries(
        diveId: diveId,
        tankId: entry.key,
        samples: [
          for (final point in entry.value)
            TankPressureSample(
              timestamp: point.timestamp,
              pressure: point.pressure,
            ),
        ],
        now: now,
      );
    }
    // Only mark parent dive as pending - child data syncs with it
    await (_db.update(_db.dives)..where((t) => t.id.equals(diveId))).write(
      DivesCompanion(updatedAt: Value(now)),
    );
    await _syncRepository.markRecordPending(
      entityType: 'dives',
      recordId: diveId,
      localUpdatedAt: now,
    );
    SyncEventBus.notifyLocalChange();
  }

  /// Delete all tank pressure data for a dive
  Future<void> deleteTankPressuresForDive(String diveId) async {
    await (_db.delete(
      _db.tankPressureProfiles,
    )..where((t) => t.diveId.equals(diveId))).go();
    await _tankSeries.deleteForDive(diveId);
    final now = DateTime.now().millisecondsSinceEpoch;
    await (_db.update(_db.dives)..where((t) => t.id.equals(diveId))).write(
      DivesCompanion(updatedAt: Value(now)),
    );
    await _syncRepository.markRecordPending(
      entityType: 'dives',
      recordId: diveId,
      localUpdatedAt: now,
    );
    SyncEventBus.notifyLocalChange();
  }

  /// Replace all tank pressure data for a dive
  ///
  /// Deletes existing data and inserts new data in a single transaction.
  Future<void> replaceTankPressures(
    String diveId,
    Map<String, List<({int timestamp, double pressure})>> pressuresByTank,
  ) async {
    await _db.transaction(() async {
      await deleteTankPressuresForDive(diveId);
      await insertTankPressures(diveId, pressuresByTank);
    });
  }

  /// Move every pressure row of [fromTankId] onto [toTankId] (wrong-cylinder
  /// repair). No transaction/notify -- the repair executor owns those.
  Future<void> reassignTankPressureSeries({
    required String diveId,
    required String fromTankId,
    required String toTankId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _tankSeries.reassignTank(diveId, fromTankId, toTankId, now: now);
    await _touchDive(diveId, now);
  }

  /// Exchange the pressure series of two tanks (swapped-transmitter repair).
  Future<void> swapTankPressureSeries({
    required String diveId,
    required String tankIdA,
    required String tankIdB,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _tankSeries.swapTanks(diveId, tankIdA, tankIdB, now: now);
    await _touchDive(diveId, now);
  }

  /// Child rows sync with the parent dive: bump + mark it pending.
  Future<void> _touchDive(String diveId, int now) async {
    await (_db.update(_db.dives)..where((t) => t.id.equals(diveId))).write(
      DivesCompanion(updatedAt: Value(now)),
    );
    await _syncRepository.markRecordPending(
      entityType: 'dives',
      recordId: diveId,
      localUpdatedAt: now,
    );
  }

  /// Check if a dive has any per-tank pressure data
  Future<bool> hasTankPressures(String diveId) async =>
      await _tankSeries.hasSeriesForDive(diveId) ||
      await _hasTankPressuresLegacy(diveId);

  Future<bool> _hasTankPressuresLegacy(String diveId) async {
    final count =
        await (_db.selectOnly(_db.tankPressureProfiles)
              ..addColumns([_db.tankPressureProfiles.id.count()])
              ..where(_db.tankPressureProfiles.diveId.equals(diveId)))
            .map((row) => row.read(_db.tankPressureProfiles.id.count()))
            .getSingle();

    return (count ?? 0) > 0;
  }
}
