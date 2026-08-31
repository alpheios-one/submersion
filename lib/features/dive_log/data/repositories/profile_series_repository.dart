import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'package:submersion/core/data/repositories/sync_repository.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/core/services/database_service.dart';
import 'package:submersion/core/services/logger_service.dart';
import 'package:submersion/core/services/sync/sync_event_bus.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_sample.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_series_codec.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_series_codec_exception.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_series_summary.dart';
import 'package:submersion/features/dive_log/domain/entities/profile_series.dart';
import 'package:submersion/features/dive_log/domain/services/profile_sample_dedupe.dart';

/// Every read and write of `dive_profile_series`. The only production code
/// that encodes or decodes profile samples, apart from the migration packer.
///
/// Zero-arg like `TankPressureRepository`: the database is the
/// `DatabaseService` singleton, so `setUpTestDatabase()` composes with it.
class ProfileSeriesRepository {
  ProfileSeriesRepository({
    SyncRepository? syncRepository,
    AppDatabase? database,
  }) : _syncRepository = syncRepository ?? SyncRepository(database: database),
       _database = database;

  /// The sync entity type; also the `hlcTargets` key.
  static const String entityType = 'diveProfileSeries';

  static const ProfileSeriesCodec _codec = ProfileSeriesCodec();

  final AppDatabase? _database;
  AppDatabase get _db => _database ?? DatabaseService.instance.database;
  final SyncRepository _syncRepository;
  final _uuid = const Uuid();
  final _log = LoggerService.forClass(ProfileSeriesRepository);

  /// Inserts one series and marks it pending so it gets an HLC.
  ///
  /// [samples] must be non-empty; any order, the repository sorts by
  /// timestamp (stable) and drops exact duplicates. Throws [ArgumentError]
  /// on an empty list. Returns the row id.
  Future<String> insertSeries({
    required String diveId,
    String? computerId,
    String? sourceId,
    bool isPrimary = true,
    required List<ProfileSample> samples,
    String? id,
    int? now,
  }) async {
    final encoded = _codec.encode(
      dedupeExactSamples(_sortedByTimestamp(samples)),
    );
    final summary = encoded.summary;
    final rowId = id ?? _uuid.v4();
    final nowMs = now ?? DateTime.now().millisecondsSinceEpoch;
    // One transaction, like every other mutator here: a row that commits
    // without its sync bookkeeping carries no HLC, and the strict watermark
    // comparison then hides it from every incremental export.
    await _db.transaction(() async {
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
    });
    SyncEventBus.notifyLocalChange();
    return rowId;
  }

  /// Timestamp order, ties in input order. Every writer hands over whatever
  /// order it has; the codec and every reader assume ascending timestamps.
  static List<ProfileSample> _sortedByTimestamp(List<ProfileSample> samples) {
    final indexed = [
      for (var i = 0; i < samples.length; i++) (samples[i].timestamp, i),
    ];
    indexed.sort((a, b) {
      final byTime = a.$1.compareTo(b.$1);
      return byTime != 0 ? byTime : a.$2.compareTo(b.$2);
    });
    return [for (final e in indexed) samples[e.$2]];
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
    return [for (final row in rows) ?_decodeOrNull(row)];
  }

  /// Every series of every dive in [diveIds], grouped by dive, each list in
  /// the same order [getSeriesForDive] uses. Dives without series are absent
  /// from the map, which is how a caller tells "not yet migrated" apart
  /// from "no samples". [diveIds] is queried in chunks (see [_chunks]), then
  /// the concatenated rows are sorted before grouping so the result is the
  /// same as one unchunked query would have produced.
  Future<Map<String, List<ProfileSeries>>> getSeriesForDives(
    List<String> diveIds,
  ) async {
    if (diveIds.isEmpty) return const {};
    final rows = await _rowsForDives(diveIds);
    final byDive = <String, List<ProfileSeries>>{};
    for (final row in rows) {
      final series = _decodeOrNull(row);
      if (series == null) continue;
      byDive.putIfAbsent(row.diveId, () => []).add(series);
    }
    return byDive;
  }

  Future<ProfileSeries?> getSeriesById(String id) async {
    final row = await (_db.select(
      _db.diveProfileSeries,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _decodeOrNull(row);
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

  /// Whether [diveId] has any series row, primary or not. The writers use it
  /// where the legacy code counted `dive_profiles` rows.
  Future<bool> hasAnySeries(String diveId) async {
    final count =
        await (_db.selectOnly(_db.diveProfileSeries)
              ..addColumns([_db.diveProfileSeries.id.count()])
              ..where(_db.diveProfileSeries.diveId.equals(diveId)))
            .map((row) => row.read(_db.diveProfileSeries.id.count()))
            .getSingle();
    return (count ?? 0) > 0;
  }

  /// Whether [computerId] already contributed a series to [diveId]; the
  /// re-download guard.
  Future<bool> hasSeriesForComputer(String diveId, String computerId) async {
    final count =
        await (_db.selectOnly(_db.diveProfileSeries)
              ..addColumns([_db.diveProfileSeries.id.count()])
              ..where(
                _db.diveProfileSeries.diveId.equals(diveId) &
                    _db.diveProfileSeries.computerId.equals(computerId),
              ))
            .map((row) => row.read(_db.diveProfileSeries.id.count()))
            .getSingle();
    return (count ?? 0) > 0;
  }

  /// Whether the source identified by [sourceId] / [computerId] owns at least
  /// one series of [diveId]: the FK first, then the legacy null-source
  /// computer rule (the same predicate every ownership write uses).
  Future<bool> ownsAny(
    String diveId, {
    required String? sourceId,
    required String? computerId,
  }) async {
    final count =
        await (_db.selectOnly(_db.diveProfileSeries)
              ..addColumns([_db.diveProfileSeries.id.count()])
              ..where(
                _db.diveProfileSeries.diveId.equals(diveId) &
                    _ownedBy(
                      _db.diveProfileSeries,
                      sourceId: sourceId,
                      computerId: computerId,
                    ),
              ))
            .map((row) => row.read(_db.diveProfileSeries.id.count()))
            .getSingle();
    return (count ?? 0) > 0;
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
  /// wants. Use [promoteWinnerOwnedBy] for a primary swap, where a series
  /// another one supersedes must stay demoted.
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

  /// Sets `is_primary` on the series [sourceId] or [computerId] own that
  /// nothing else the source owns supersedes. Returns the promoted ids,
  /// empty when the source owns nothing.
  ///
  /// Ranking: the null-computer series first (a manual edit is the live
  /// version of its source's samples, the rule `restoreOriginalProfile`
  /// encodes), then the greatest id. Both halves are derived from synced
  /// values, so every device resolves the same winners.
  ///
  /// A lower-ranked series is superseded only where it overlaps a winner in
  /// time. `saveEditedProfile` does not replace what it supersedes: it
  /// demotes the original and inserts a second, null-computer generation
  /// over the same timestamps, so promoting the whole owned set would
  /// resurrect the original alongside the edit. That is what the retired
  /// row-per-sample SQL expressed as `ROW_NUMBER() OVER (PARTITION BY
  /// p.timestamp ...) WHERE rn = 1`: the winner at each timestamp. A series
  /// covering a range no winner touches loses no timestamp to a rival, so it
  /// is promoted too. Promoting only one series would have handed half its
  /// profile back to any dive whose source owns two segments over disjoint
  /// ranges, which is what a merge of one computer's split dive writes.
  ///
  /// The overlap test uses the stored `start_timestamp` / `end_timestamp`
  /// summary columns, so no blob is decoded: a superseding generation shares
  /// its original's range, and two segments of one dive do not.
  Future<List<String>> promoteWinnerOwnedBy(
    String diveId, {
    required String? sourceId,
    required String? computerId,
    int? now,
  }) async {
    final nowMs = now ?? DateTime.now().millisecondsSinceEpoch;
    final owned =
        await (_db.select(_db.diveProfileSeries)
              ..where(
                (t) =>
                    t.diveId.equals(diveId) &
                    _ownedBy(t, sourceId: sourceId, computerId: computerId),
              )
              ..orderBy([
                (t) => OrderingTerm.desc(t.computerId.isNull()),
                (t) => OrderingTerm.desc(t.id),
              ]))
            .get();
    if (owned.isEmpty) return const [];
    final winners = <DiveProfileSeriesRow>[];
    for (final candidate in owned) {
      final superseded = winners.any(
        (winner) =>
            candidate.startTimestamp <= winner.endTimestamp &&
            winner.startTimestamp <= candidate.endTimestamp,
      );
      if (!superseded) winners.add(candidate);
    }
    final ids = [for (final winner in winners) winner.id];
    await _db.transaction(() async {
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
    });
    SyncEventBus.notifyLocalChange();
    return ids;
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

  /// Stamps [sourceId] on every series of [diveId] that has no source yet
  /// (the first `dive_data_sources` row of a dive adopts the unattributed
  /// profile, issue #1149). Returns the number of series stamped.
  Future<int> adoptUnattributed(
    String diveId,
    String sourceId, {
    int? now,
  }) async {
    final nowMs = now ?? DateTime.now().millisecondsSinceEpoch;
    final ids = await _ids(
      (t) => t.diveId.equals(diveId) & t.sourceId.isNull(),
    );
    if (ids.isEmpty) return 0;
    await _db.transaction(() async {
      await (_db.update(
        _db.diveProfileSeries,
      )..where((t) => t.id.isIn(ids))).write(
        DiveProfileSeriesCompanion(
          sourceId: Value(sourceId),
          updatedAt: Value(nowMs),
        ),
      );
      for (final id in ids) {
        await _markPending(id, nowMs);
      }
    });
    return ids.length;
  }

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

  /// Deletes the series [computerId] contributed to [diveId]; a null
  /// [computerId] matches the null-computer (manual or file) series only.
  /// One tombstone per series. Returns the deleted ids.
  Future<List<String>> deleteByComputer(String diveId, String? computerId) =>
      _delete(
        (t) =>
            t.diveId.equals(diveId) &
            (computerId == null
                ? t.computerId.isNull()
                : t.computerId.equals(computerId)),
      );

  /// Deletes exactly [ids], one tombstone each. Empty input is a no-op.
  Future<List<String>> deleteByIds(List<String> ids) =>
      ids.isEmpty ? Future.value(const []) : _delete((t) => t.id.isIn(ids));

  /// Nulls `computer_id` on every series of [computerId] and restamps each
  /// (the FK's ON DELETE SET NULL would change the rows without an hlc bump,
  /// so peers would never learn). Returns the number of series touched.
  Future<int> clearComputer(String computerId, {int? now}) =>
      _setComputer(null, (t) => t.computerId.equals(computerId), now: now);

  /// Diver reassignment: a computer that now belongs to [diverId] must not
  /// stay attributed on dives the diver does not own.
  Future<int> clearComputersOfDiverForForeignDives(
    String diverId, {
    int? now,
  }) => _setComputer(
    null,
    (t) =>
        t.computerId.isInQuery(
          _db.selectOnly(_db.diveComputers)
            ..addColumns([_db.diveComputers.id])
            ..where(_db.diveComputers.diverId.equals(diverId)),
        ) &
        t.diveId.isNotInQuery(
          _db.selectOnly(_db.dives)
            ..addColumns([_db.dives.id])
            ..where(_db.dives.diverId.equals(diverId)),
        ),
    now: now,
  );

  /// A recreated computer takes back the null-computer series of [diveIds]
  /// whose only computer source is the one being relinked (the legacy
  /// `dive_profiles` relink, series twin).
  Future<int> relinkComputer(
    String computerId,
    List<String> diveIds, {
    int? now,
  }) {
    if (diveIds.isEmpty) return Future.value(0);
    return _setComputer(
      computerId,
      (t) =>
          t.computerId.isNull() &
          t.diveId.isIn(diveIds) &
          t.diveId.isInQuery(
            _db.selectOnly(_db.diveDataSources)
              ..addColumns([_db.diveDataSources.diveId])
              ..where(_db.diveDataSources.sourceFormat.equals('dive_computer'))
              ..groupBy([
                _db.diveDataSources.diveId,
              ], having: _db.diveDataSources.id.count().equals(1)),
          ),
      now: now,
    );
  }

  Future<int> _setComputer(
    String? computerId,
    Expression<bool> Function($DiveProfileSeriesTable t) where, {
    int? now,
  }) async {
    final nowMs = now ?? DateTime.now().millisecondsSinceEpoch;
    final ids = await _ids(where);
    if (ids.isEmpty) return 0;
    await _db.transaction(() async {
      await (_db.update(
        _db.diveProfileSeries,
      )..where((t) => t.id.isIn(ids))).write(
        DiveProfileSeriesCompanion(
          computerId: Value(computerId),
          updatedAt: Value(nowMs),
        ),
      );
      for (final id in ids) {
        await _markPending(id, nowMs);
      }
    });
    return ids.length;
  }

  /// Raw rows of every series of [diveIds], undecoded, for snapshots that
  /// restore them verbatim through [restoreSeriesRow].
  Future<List<DiveProfileSeriesRow>> getRowsForDives(
    List<String> diveIds,
  ) async {
    if (diveIds.isEmpty) return const [];
    return _rowsForDives(diveIds);
  }

  /// [diveIds] queried in chunks of at most [_chunkSize], concatenated and
  /// sorted by `(diveId, startTimestamp, id)`, which is the order a single
  /// unchunked query with that `ORDER BY` would have returned.
  ///
  /// Binding one SQL variable per dive id means an unchunked `IN (...)`
  /// clause over a whole library's filtered dive ids can exceed the
  /// engine's bound-variable ceiling. `DecoClassificationCacheRepository`
  /// measured that ceiling against the bundled engine at 32766 (SQLite's
  /// 3.32+ default): an unchunked query survives 2500 ids and only throws
  /// "too many SQL variables" past that. The chunk size stays at 900 for
  /// consistency with that repository and `SpeciesRepository` rather than
  /// for necessity.
  Future<List<DiveProfileSeriesRow>> _rowsForDives(List<String> diveIds) async {
    final rows = <DiveProfileSeriesRow>[];
    for (final chunk in _chunks(diveIds)) {
      rows.addAll(
        await (_db.select(
          _db.diveProfileSeries,
        )..where((t) => t.diveId.isIn(chunk))).get(),
      );
    }
    rows.sort(_byDiveStartId);
    return rows;
  }

  static const int _chunkSize =
      900; // safely under SQLite's bound-variable limit

  static Iterable<List<String>> _chunks(List<String> ids) sync* {
    for (var start = 0; start < ids.length; start += _chunkSize) {
      final end = start + _chunkSize < ids.length
          ? start + _chunkSize
          : ids.length;
      yield ids.sublist(start, end);
    }
  }

  static int _byDiveStartId(DiveProfileSeriesRow a, DiveProfileSeriesRow b) {
    final byDive = a.diveId.compareTo(b.diveId);
    if (byDive != 0) return byDive;
    final byStart = a.startTimestamp.compareTo(b.startTimestamp);
    if (byStart != 0) return byStart;
    return a.id.compareTo(b.id);
  }

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

  /// Decodes one row, or returns null when its blob does not decode.
  ///
  /// One unreadable blob (a decode failure the writer never should have let
  /// through, but storage can still bit-rot) skips its own series rather
  /// than failing every read that touches the dive: the retired row-per-
  /// sample read could only ever return fewer rows, and
  /// `series_profile_aggregates._decodeStreams` already applies this policy.
  ProfileSeries? _decodeOrNull(DiveProfileSeriesRow row) {
    final List<ProfileSample> samples;
    try {
      samples = _codec.decode(row.samples);
    } on ProfileSeriesCodecException catch (e) {
      _log.warning('Skipping unreadable diveProfileSeries ${row.id}: $e');
      return null;
    }
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
      samples: samples,
      codecVersion: row.codecVersion,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      hlc: row.hlc,
    );
  }
}
