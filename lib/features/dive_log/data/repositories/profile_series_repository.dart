import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'package:submersion/core/data/repositories/sync_repository.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/core/services/database_service.dart';
import 'package:submersion/core/services/sync/sync_event_bus.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_sample.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_series_codec.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_series_summary.dart';
import 'package:submersion/features/dive_log/domain/entities/profile_series.dart';
import 'package:submersion/features/dive_log/domain/services/profile_sample_dedupe.dart';

/// Every read and write of `dive_profile_series`. The only production code
/// that encodes or decodes profile samples, apart from the migration packer.
///
/// Zero-arg like `TankPressureRepository`: the database is the
/// `DatabaseService` singleton, so `setUpTestDatabase()` composes with it.
class ProfileSeriesRepository {
  ProfileSeriesRepository({SyncRepository? syncRepository})
    : _syncRepository = syncRepository ?? SyncRepository();

  /// The sync entity type; also the `hlcTargets` key.
  static const String entityType = 'diveProfileSeries';

  static const ProfileSeriesCodec _codec = ProfileSeriesCodec();

  AppDatabase get _db => DatabaseService.instance.database;
  final SyncRepository _syncRepository;
  final _uuid = const Uuid();

  /// Inserts one series and marks it pending so it gets an HLC.
  ///
  /// [samples] must be non-empty and timestamp-ordered; exact duplicates are
  /// dropped. Throws [ArgumentError] on an empty list. Returns the row id.
  Future<String> insertSeries({
    required String diveId,
    String? computerId,
    String? sourceId,
    bool isPrimary = true,
    required List<ProfileSample> samples,
    String? id,
    int? now,
  }) async {
    final encoded = _codec.encode(dedupeExactSamples(samples));
    final summary = encoded.summary;
    final rowId = id ?? _uuid.v4();
    final nowMs = now ?? DateTime.now().millisecondsSinceEpoch;
    await _db
        .into(_db.diveProfileSeries)
        .insert(
          DiveProfileSeriesCompanion.insert(
            id: rowId,
            diveId: diveId,
            computerId: Value(computerId),
            sourceId: Value(sourceId),
            isPrimary: Value(isPrimary),
            sampleCount: summary.sampleCount,
            startTimestamp: summary.startTimestamp,
            endTimestamp: summary.endTimestamp,
            maxDepth: summary.maxDepth,
            firstDepth: summary.firstDepth,
            lastDepth: summary.lastDepth,
            hasDecoType: Value(summary.hasDecoType),
            hasDecoStop: Value(summary.hasDecoStop),
            hasPositiveCeiling: Value(summary.hasPositiveCeiling),
            codecVersion: encoded.codecVersion,
            samples: encoded.bytes,
            createdAt: nowMs,
            updatedAt: nowMs,
          ),
        );
    await _markPending(rowId, nowMs);
    SyncEventBus.notifyLocalChange();
    return rowId;
  }

  /// Every series of [diveId], decoded, oldest start first and then by id
  /// so the order is stable. [primaryOnly] keeps only `is_primary` rows.
  Future<List<ProfileSeries>> getSeriesForDive(
    String diveId, {
    bool primaryOnly = false,
  }) async {
    final query = _db.select(_db.diveProfileSeries)
      ..where((t) => t.diveId.equals(diveId))
      ..orderBy([
        (t) => OrderingTerm.asc(t.startTimestamp),
        (t) => OrderingTerm.asc(t.id),
      ]);
    if (primaryOnly) {
      query.where((t) => t.isPrimary.equals(true));
    }
    final rows = await query.get();
    return [for (final row in rows) _decode(row)];
  }

  Future<ProfileSeries?> getSeriesById(String id) async {
    final row = await (_db.select(
      _db.diveProfileSeries,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _decode(row);
  }

  /// Clears `is_primary` on every series of [diveId]. Returns how many rows
  /// changed; each changed row is marked pending.
  Future<int> demoteAll(String diveId, {int? now}) async {
    final nowMs = now ?? DateTime.now().millisecondsSinceEpoch;
    final ids = await _ids((t) => t.diveId.equals(diveId));
    if (ids.isEmpty) return 0;
    await (_db.update(
      _db.diveProfileSeries,
    )..where((t) => t.id.isIn(ids))).write(
      DiveProfileSeriesCompanion(
        isPrimary: const Value(false),
        updatedAt: Value(nowMs),
      ),
    );
    for (final id in ids) {
      await _markPending(id, nowMs);
    }
    SyncEventBus.notifyLocalChange();
    return ids.length;
  }

  /// Sets `is_primary` on the series [sourceId] or [computerId] own.
  ///
  /// Ownership is the FK first, then the pre-v154 computer convention for
  /// rows that carry no source: `source_id = ?` OR (`source_id IS NULL` AND
  /// `computer_id IS ?`). The IS-semantics on the computer id are load
  /// bearing: `=` never matches NULL, which is how issue #1149 began.
  Future<int> promoteOwnedBy(
    String diveId, {
    required String? sourceId,
    required String? computerId,
    int? now,
  }) async {
    final nowMs = now ?? DateTime.now().millisecondsSinceEpoch;
    final ids = await _ids(
      (t) =>
          t.diveId.equals(diveId) &
          _ownedBy(t, sourceId: sourceId, computerId: computerId),
    );
    if (ids.isEmpty) return 0;
    await (_db.update(
      _db.diveProfileSeries,
    )..where((t) => t.id.isIn(ids))).write(
      DiveProfileSeriesCompanion(
        isPrimary: const Value(true),
        updatedAt: Value(nowMs),
      ),
    );
    for (final id in ids) {
      await _markPending(id, nowMs);
    }
    SyncEventBus.notifyLocalChange();
    return ids.length;
  }

  /// Deletes the series [sourceId] or [computerId] own (see
  /// [promoteOwnedBy] for the predicate), one tombstone per series.
  /// Returns the deleted ids.
  Future<List<String>> deleteOwnedBy(
    String diveId, {
    required String? sourceId,
    required String? computerId,
  }) => _delete(
    (t) =>
        t.diveId.equals(diveId) &
        _ownedBy(t, sourceId: sourceId, computerId: computerId),
  );

  /// Deletes every series of [diveId], one tombstone per series.
  Future<List<String>> deleteForDive(String diveId) =>
      _delete((t) => t.diveId.equals(diveId));

  Expression<bool> _ownedBy(
    $DiveProfileSeriesTable t, {
    required String? sourceId,
    required String? computerId,
  }) {
    final bySource = sourceId == null
        ? const Constant<bool>(false)
        : t.sourceId.equals(sourceId);
    final byComputer =
        t.sourceId.isNull() &
        (computerId == null
            ? t.computerId.isNull()
            : t.computerId.equals(computerId));
    return bySource | byComputer;
  }

  Future<List<String>> _ids(
    Expression<bool> Function($DiveProfileSeriesTable t) where,
  ) async {
    final query = _db.selectOnly(_db.diveProfileSeries)
      ..addColumns([_db.diveProfileSeries.id])
      ..where(where(_db.diveProfileSeries));
    final rows = await query.get();
    return [for (final row in rows) row.read(_db.diveProfileSeries.id)!];
  }

  Future<List<String>> _delete(
    Expression<bool> Function($DiveProfileSeriesTable t) where,
  ) async {
    final ids = await _ids(where);
    if (ids.isEmpty) return ids;
    for (final id in ids) {
      await _syncRepository.logDeletion(entityType: entityType, recordId: id);
    }
    await (_db.delete(
      _db.diveProfileSeries,
    )..where((t) => t.id.isIn(ids))).go();
    SyncEventBus.notifyLocalChange();
    return ids;
  }

  Future<void> _markPending(String id, int nowMs) =>
      _syncRepository.markRecordPending(
        entityType: entityType,
        recordId: id,
        localUpdatedAt: nowMs,
      );

  ProfileSeries _decode(DiveProfileSeriesRow row) {
    return ProfileSeries(
      id: row.id,
      diveId: row.diveId,
      computerId: row.computerId,
      sourceId: row.sourceId,
      isPrimary: row.isPrimary,
      summary: ProfileSeriesSummary(
        sampleCount: row.sampleCount,
        startTimestamp: row.startTimestamp,
        endTimestamp: row.endTimestamp,
        maxDepth: row.maxDepth,
        firstDepth: row.firstDepth,
        lastDepth: row.lastDepth,
        hasDecoType: row.hasDecoType,
        hasDecoStop: row.hasDecoStop,
        hasPositiveCeiling: row.hasPositiveCeiling,
      ),
      samples: _codec.decode(row.samples),
      codecVersion: row.codecVersion,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      hlc: row.hlc,
    );
  }
}
