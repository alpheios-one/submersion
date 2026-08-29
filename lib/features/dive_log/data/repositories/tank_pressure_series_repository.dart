import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'package:submersion/core/data/repositories/sync_repository.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/core/services/database_service.dart';
import 'package:submersion/core/services/sync/sync_event_bus.dart';
import 'package:submersion/features/dive_log/domain/codecs/tank_pressure_series_codec.dart';
import 'package:submersion/features/dive_log/domain/entities/profile_series.dart'
    as domain;
import 'package:submersion/features/dive_log/domain/services/profile_sample_dedupe.dart';

/// Every read and write of `tank_pressure_series`. See
/// `ProfileSeriesRepository` for the conventions; this is its two-field
/// sibling keyed by (dive, tank, computer).
class TankPressureSeriesRepository {
  TankPressureSeriesRepository({SyncRepository? syncRepository})
    : _syncRepository = syncRepository ?? SyncRepository();

  static const String entityType = 'tankPressureSeries';

  static const TankPressureSeriesCodec _codec = TankPressureSeriesCodec();

  AppDatabase get _db => DatabaseService.instance.database;
  final SyncRepository _syncRepository;
  final _uuid = const Uuid();

  /// Inserts one series and marks it pending. [samples] must be non-empty
  /// and timestamp-ordered; exact duplicates are dropped. Returns the id.
  Future<String> insertSeries({
    required String diveId,
    required String tankId,
    String? computerId,
    required List<TankPressureSample> samples,
    String? id,
    int? now,
  }) async {
    final encoded = _codec.encode(dedupeExactPressureSamples(samples));
    final rowId = id ?? _uuid.v4();
    final nowMs = now ?? DateTime.now().millisecondsSinceEpoch;
    await _db
        .into(_db.tankPressureSeries)
        .insert(
          TankPressureSeriesCompanion.insert(
            id: rowId,
            diveId: diveId,
            tankId: tankId,
            computerId: Value(computerId),
            sampleCount: encoded.summary.sampleCount,
            startTimestamp: encoded.summary.startTimestamp,
            endTimestamp: encoded.summary.endTimestamp,
            codecVersion: encoded.codecVersion,
            samples: encoded.bytes,
            createdAt: nowMs,
            updatedAt: nowMs,
          ),
        );
    await _syncRepository.markRecordPending(
      entityType: entityType,
      recordId: rowId,
      localUpdatedAt: nowMs,
    );
    SyncEventBus.notifyLocalChange();
    return rowId;
  }

  /// Every series of [diveId], by tank then start then id.
  Future<List<domain.TankPressureSeries>> getSeriesForDive(
    String diveId,
  ) async {
    final rows =
        await (_db.select(_db.tankPressureSeries)
              ..where((t) => t.diveId.equals(diveId))
              ..orderBy([
                (t) => OrderingTerm.asc(t.tankId),
                (t) => OrderingTerm.asc(t.startTimestamp),
                (t) => OrderingTerm.asc(t.id),
              ]))
            .get();
    return [for (final row in rows) _decode(row)];
  }

  Future<List<domain.TankPressureSeries>> getSeriesForTank(
    String diveId,
    String tankId,
  ) async {
    final rows =
        await (_db.select(_db.tankPressureSeries)
              ..where((t) => t.diveId.equals(diveId) & t.tankId.equals(tankId))
              ..orderBy([
                (t) => OrderingTerm.asc(t.startTimestamp),
                (t) => OrderingTerm.asc(t.id),
              ]))
            .get();
    return [for (final row in rows) _decode(row)];
  }

  Future<List<String>> deleteForDive(String diveId) =>
      _delete((t) => t.diveId.equals(diveId));

  Future<List<String>> deleteForTank(String diveId, String tankId) =>
      _delete((t) => t.diveId.equals(diveId) & t.tankId.equals(tankId));

  /// Deletes the series [computerId] contributed; a null [computerId]
  /// matches the null-computer (manual or primary-source) rows only.
  Future<List<String>> deleteOwnedByComputer(
    String diveId,
    String? computerId,
  ) => _delete(
    (t) =>
        t.diveId.equals(diveId) &
        (computerId == null
            ? t.computerId.isNull()
            : t.computerId.equals(computerId)),
  );

  /// Re-inserts [row] verbatim, `created_at`, `updated_at` and `hlc`
  /// included: consolidation undo puts back the row it captured rather than
  /// re-encoding it. When [markPending] the row is queued for sync, which
  /// restamps its hlc so the restore wins last-writer-wins on every peer.
  Future<void> restoreSeriesRow(
    TankPressureSeriesRow row, {
    bool markPending = true,
    int? now,
  }) async {
    await _db.transaction(() async {
      await _db
          .into(_db.tankPressureSeries)
          .insertOnConflictUpdate(row.toCompanion(false));
      // The delete that preceded a restore logged a tombstone; left in place
      // it would ride the next changeset beside the upsert and delete the
      // restored row on every peer.
      await _syncRepository.removeDeletion(
        entityType: entityType,
        recordId: row.id,
      );
      if (markPending) {
        await _syncRepository.markRecordPending(
          entityType: entityType,
          recordId: row.id,
          localUpdatedAt: now ?? DateTime.now().millisecondsSinceEpoch,
        );
      }
    });
    SyncEventBus.notifyLocalChange();
  }

  Future<List<String>> _delete(
    Expression<bool> Function($TankPressureSeriesTable t) where,
  ) async {
    final query = _db.selectOnly(_db.tankPressureSeries)
      ..addColumns([_db.tankPressureSeries.id])
      ..where(where(_db.tankPressureSeries));
    final ids = [
      for (final row in await query.get()) row.read(_db.tankPressureSeries.id)!,
    ];
    if (ids.isEmpty) return ids;
    // The tombstones and the delete are one logical write. A failure between
    // them would leave tombstones for rows that are still live here, and the
    // next sync would delete them on every peer.
    await _db.transaction(() async {
      for (final id in ids) {
        await _syncRepository.logDeletion(entityType: entityType, recordId: id);
      }
      await (_db.delete(
        _db.tankPressureSeries,
      )..where((t) => t.id.isIn(ids))).go();
    });
    SyncEventBus.notifyLocalChange();
    return ids;
  }

  domain.TankPressureSeries _decode(TankPressureSeriesRow row) {
    return domain.TankPressureSeries(
      id: row.id,
      diveId: row.diveId,
      tankId: row.tankId,
      computerId: row.computerId,
      summary: TankPressureSeriesSummary(
        sampleCount: row.sampleCount,
        startTimestamp: row.startTimestamp,
        endTimestamp: row.endTimestamp,
      ),
      samples: _codec.decode(row.samples),
      codecVersion: row.codecVersion,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      hlc: row.hlc,
    );
  }
}
