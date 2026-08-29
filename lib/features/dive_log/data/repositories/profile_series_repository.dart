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

  /// Whether [diveId] has any primary series. A count, so no blob is read
  /// or decoded.
  Future<bool> hasPrimarySeries(String diveId) async {
    final count = _db.diveProfileSeries.id.count();
    final query = _db.selectOnly(_db.diveProfileSeries)
      ..addColumns([count])
      ..where(
        _db.diveProfileSeries.diveId.equals(diveId) &
            _db.diveProfileSeries.isPrimary.equals(true),
      );
    return ((await query.getSingle()).read(count) ?? 0) > 0;
  }

  /// Clears `is_primary` on the primary series of [diveId]. Returns how many
  /// rows changed; each changed row is marked pending. Series that are
  /// already demoted are not touched, so an untouched row keeps its
  /// `updated_at` and stays out of the next changeset.
  Future<int> demoteAll(String diveId, {int? now}) => _setPrimary(
    (t) => t.diveId.equals(diveId) & t.isPrimary.equals(true),
    value: false,
    now: now,
  );

  /// Sets `is_primary` on the series [sourceId] or [computerId] own.
  ///
  /// Ownership is the FK first, then the pre-v154 computer convention for
  /// rows that carry no source: `source_id = ?` OR (`source_id IS NULL` AND
  /// `computer_id IS ?`). The IS-semantics on the computer id are load
  /// bearing: `=` never matches NULL, which is how issue #1149 began.
  ///
  /// Promotes EVERY series the source owns, which is what the split path
  /// wants. Use [promoteWinnerOwnedBy] for a primary swap, where exactly one
  /// of them may end up live.
  Future<int> promoteOwnedBy(
    String diveId, {
    required String? sourceId,
    required String? computerId,
    int? now,
  }) => _setPrimary(
    (t) =>
        t.diveId.equals(diveId) &
        _ownedBy(t, sourceId: sourceId, computerId: computerId),
    value: true,
    now: now,
  );

  /// Sets `is_primary` on exactly one of the series [sourceId] or
  /// [computerId] own: the null-computer one first (a manual edit is the
  /// live version of its source's samples, the rule `restoreOriginalProfile`
  /// encodes), then the greatest id. Both halves are derived from synced
  /// values, so every device resolves the same winner. Returns the promoted
  /// id, or null when the source owns nothing.
  Future<String?> promoteWinnerOwnedBy(
    String diveId, {
    required String? sourceId,
    required String? computerId,
    int? now,
  }) async {
    final nowMs = now ?? DateTime.now().millisecondsSinceEpoch;
    final query = _db.select(_db.diveProfileSeries)
      ..where(
        (t) =>
            t.diveId.equals(diveId) &
            _ownedBy(t, sourceId: sourceId, computerId: computerId),
      )
      ..orderBy([
        (t) => OrderingTerm.desc(t.computerId.isNull()),
        (t) => OrderingTerm.desc(t.id),
      ])
      ..limit(1);
    final winner = await query.getSingleOrNull();
    if (winner == null) return null;
    await _db.transaction(() async {
      await (_db.update(
        _db.diveProfileSeries,
      )..where((t) => t.id.equals(winner.id))).write(
        DiveProfileSeriesCompanion(
          isPrimary: const Value(true),
          updatedAt: Value(nowMs),
        ),
      );
      await _markPending(winner.id, nowMs);
    });
    SyncEventBus.notifyLocalChange();
    return winner.id;
  }

  /// Sets `is_primary` on every series [computerId] contributed, whatever
  /// source they carry. The multi-computer branch of a profile restore, where
  /// each computer's own samples become live again.
  Future<int> promoteByComputer(String diveId, String computerId, {int? now}) =>
      _setPrimary(
        (t) => t.diveId.equals(diveId) & t.computerId.equals(computerId),
        value: true,
        now: now,
      );

  /// Sets `is_primary` on every series of [diveId]. The single-computer
  /// branch of a profile restore, where nothing else can be the live series.
  Future<int> promoteAll(String diveId, {int? now}) =>
      _setPrimary((t) => t.diveId.equals(diveId), value: true, now: now);

  /// Re-inserts [row] verbatim, `created_at`, `updated_at` and `hlc`
  /// included: consolidation undo puts back the row it captured rather than
  /// re-encoding it, and a re-encode could differ byte for byte. When
  /// [markPending] the row is queued for sync, which restamps its hlc so the
  /// restore wins last-writer-wins on every peer.
  Future<void> restoreSeriesRow(
    DiveProfileSeriesRow row, {
    bool markPending = true,
    int? now,
  }) async {
    await _db.transaction(() async {
      await _db
          .into(_db.diveProfileSeries)
          .insertOnConflictUpdate(row.toCompanion(false));
      // The delete that preceded a restore logged a tombstone; left in place
      // it would ride the next changeset beside the upsert and delete the
      // restored row on every peer.
      await _syncRepository.removeDeletion(
        entityType: entityType,
        recordId: row.id,
      );
      if (markPending) {
        await _markPending(
          row.id,
          now ?? DateTime.now().millisecondsSinceEpoch,
        );
      }
    });
    SyncEventBus.notifyLocalChange();
  }

  /// Writes `is_primary` = [value] on every matching series, marking each
  /// changed row pending. The write and the pending stamps are one
  /// transaction: a failure between them would leave rows whose flag moved
  /// but which no changeset will ever carry.
  Future<int> _setPrimary(
    Expression<bool> Function($DiveProfileSeriesTable t) where, {
    required bool value,
    required int? now,
  }) async {
    final nowMs = now ?? DateTime.now().millisecondsSinceEpoch;
    final ids = await _ids(where);
    if (ids.isEmpty) return 0;
    await _db.transaction(() async {
      await (_db.update(
        _db.diveProfileSeries,
      )..where((t) => t.id.isIn(ids))).write(
        DiveProfileSeriesCompanion(
          isPrimary: Value(value),
          updatedAt: Value(nowMs),
        ),
      );
      for (final id in ids) {
        await _markPending(id, nowMs);
      }
    });
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

  /// Deletes the manual-edit series of [diveId]: primary and with no
  /// computer, which is exactly the set `restoreOriginalProfile` removes
  /// before putting a computer's own samples back. Returns the deleted ids,
  /// one tombstone each.
  Future<List<String>> deleteEditedSeries(String diveId) => _delete(
    (t) =>
        t.diveId.equals(diveId) &
        t.isPrimary.equals(true) &
        t.computerId.isNull(),
  );

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
    // The tombstones and the delete are one logical write. A failure between
    // them would leave tombstones for rows that are still live here, and the
    // next sync would delete them on every peer.
    await _db.transaction(() async {
      for (final id in ids) {
        await _syncRepository.logDeletion(entityType: entityType, recordId: id);
      }
      await (_db.delete(
        _db.diveProfileSeries,
      )..where((t) => t.id.isIn(ids))).go();
    });
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
