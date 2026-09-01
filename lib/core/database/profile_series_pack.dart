import 'package:drift/drift.dart';
import 'package:submersion/core/database/profile_series_pack_rows.dart';
import 'package:submersion/core/services/sync/hlc.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_sample.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_series_codec.dart';
import 'package:submersion/features/dive_log/domain/codecs/tank_pressure_series_codec.dart';
import 'package:submersion/features/dive_log/domain/entities/profile_series_identity.dart';
import 'package:submersion/features/dive_log/domain/services/profile_sample_dedupe.dart';

/// What one packing pass inserted, dropped, and skipped.
typedef ProfilePackReport = ({
  int profileSeries,
  int tankSeries,
  int droppedSamples,
  int skippedOrphans,

  /// Legacy rows without a timestamp or depth (pressure, tank id for tanks),
  /// stepped over.
  int skippedRows,

  /// Dives the packer could not read or encode, counted once per dive per
  /// legacy table and stepped over.
  ///
  /// A legacy table can hold a value no reader expects: a text depth in a
  /// REAL column from a hand-repaired or bit-rotted file, or a group the
  /// codec refuses to encode. Isolating it per dive is what keeps one such
  /// row from costing every dive the scan had not reached yet, which after
  /// v183 (when nothing reads the legacy tables any more) would be a
  /// silent, permanent loss rather than a deferred retry.
  int failedDives,

  /// Dives whose legacy (or staged) rows were discarded because the dive
  /// already had a series row, counted once per dive per legacy table.
  ///
  /// Expected and harmless on the migration path: a retried ladder, or the
  /// beforeOpen backstop after the rung already packed, sees every dive this
  /// way. On the receive-side staging path it is the count that says an
  /// older peer's row-per-sample copy of a dive lost to the series this
  /// device already holds, which is the intended precedence but worth being
  /// able to see in the sync log.
  int skippedAlreadyPacked,
});

/// Packs every legacy `dive_profiles` and `tank_pressure_profiles` row into
/// the series tables (v182, spec 2026-08-28-profile-sample-storage).
///
/// Raw SQL throughout, never the legacy Drift classes: plan 2e removed those
/// classes and dropped the tables, and this function has to keep compiling
/// and keep no-oping on a database that has already lost them.
///
/// Memory is bounded by one dive's rows, never the table. Each identity group
/// becomes one row whose id is derived from the tuple
/// ([profileSeriesMigratedId]), so a second run, a retry after a failed
/// ladder, or a second device migrating the same synced rows all converge on
/// the same id: the insert is `INSERT OR IGNORE`.
///
/// Only dives with legacy rows and no series row are visited, which is what
/// lets the beforeOpen backstop call this on every open. Exact duplicate
/// samples (a repeated import) are dropped before packing, which is what
/// every read did on the way out until now.
///
/// Orphans are skipped and counted in [ProfilePackReport.skippedOrphans]: a
/// legacy row whose dive (or, for a pressure row, whose tank) is already
/// gone could never have been rendered, and under `PRAGMA foreign_keys = ON`
/// inserting it would abort the whole ladder on every retry. A dangling
/// `computer_id` or `source_id` is weaker: the samples are still the dive's,
/// so the group packs with that member resolved to null, and the derived id
/// uses the resolved value so every device agrees.
///
/// Both legacy tables are read through `PRAGMA table_info`: a database from
/// a very old backup can lack the identity columns entirely. A missing
/// `computer_id`/`source_id` reads as null, a missing `is_primary` as true,
/// and a table without `dive_id`, `timestamp`, or `depth` (`pressure` for
/// tanks) holds nothing packable and is skipped whole.
///
/// [nowMs] stamps `created_at` and `updated_at`; `hlc` advances the clock
/// persisted in `sync_metadata` so the first sync after the upgrade
/// publishes the rows. A device that never synced has nothing to publish to
/// and stays unstamped until a base publish, which exports everything.
///
/// [profileTable] / [tankTable] default to the legacy table names the v182
/// migration and the beforeOpen backstop read. `legacy_sample_staging.dart`
/// passes its own TEMP staging table names instead, so this same function
/// packs an older peer's inbound row-per-sample rows once the real
/// `dive_profiles` / `tank_pressure_profiles` tables are gone (v183).
///
/// A dive whose legacy rows are ALL malformed (null timestamp or depth) gets
/// no series row and is rescanned on every open; that is a bounded per-open
/// cost on a damaged database, not a retry bug.
Future<ProfilePackReport> packLegacyProfileRows(
  DatabaseConnectionUser db, {
  int? nowMs,
  String profileTable = 'dive_profiles',
  String tankTable = 'tank_pressure_profiles',
}) async {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final profileColumns = await _columnNames(db, profileTable);
  final canPackProfiles = profileColumns.containsAll(const {
    'dive_id',
    'timestamp',
    'depth',
  });
  final tankColumns = await _columnNames(db, tankTable);
  final canPackTanks = tankColumns.containsAll(const {
    'dive_id',
    'tank_id',
    'timestamp',
    'pressure',
  });
  final profileScan = canPackProfiles
      ? await _scanLegacyDives(
          db,
          legacyTable: profileTable,
          seriesTable: 'dive_profile_series',
          byTank: false,
        )
      : _emptyScan;
  if (canPackTanks) await _adoptStrandedTankPressures(db, tankTable);
  final tankScan = canPackTanks
      ? await _scanLegacyDives(
          db,
          legacyTable: tankTable,
          seriesTable: 'tank_pressure_series',
          byTank: true,
        )
      : _emptyScan;
  final unpackedProfileDives = profileScan.unpacked;
  final unpackedTankDives = tankScan.unpacked;
  final alreadyPacked = profileScan.alreadyPacked + tankScan.alreadyPacked;
  if (unpackedProfileDives.isEmpty && unpackedTankDives.isEmpty) {
    // The common case on every open once a database is packed: nothing to
    // do, so nothing else is loaded. The already-packed count still rides
    // out, because this is the branch a late legacy row for a packed dive
    // takes.
    return (
      profileSeries: 0,
      tankSeries: 0,
      droppedSamples: 0,
      skippedOrphans: 0,
      skippedRows: 0,
      failedDives: 0,
      skippedAlreadyPacked: alreadyPacked,
    );
  }
  final hlc = await _migrationHlc(db, now);
  // The identities already packed. A dive reaches the loops below when ANY
  // of its rows is uncovered, so each group still has to be checked: without
  // this, re-visiting a half-packed dive would write a second series for an
  // identity that already has one (its id is a fresh uuid when the existing
  // series came from ordinary use rather than a migration, so INSERT OR
  // IGNORE would not catch it) and the dive would read as doubled samples.
  final coveredProfiles = await _coveredProfileIdentities(db);
  final coveredTanks = await _coveredTankIdentities(db);
  final diveIds = await _parentIds(db, 'dives');
  final computerIds = await _parentIds(db, 'dive_computers');
  final sourceIds = await _parentIds(db, 'dive_data_sources');
  final tankIds = await _parentIds(db, 'dive_tanks');
  var profileSeries = 0;
  var tankSeries = 0;
  var dropped = 0;
  var skipped = 0;
  var skippedRows = 0;
  var failedDives = 0;

  if (canPackProfiles) {
    const codec = ProfileSeriesCodec();
    final hasPrimary = profileColumns.contains('is_primary');
    for (final diveId in unpackedProfileDives) {
      // One transaction per dive. Each group's INSERT would otherwise
      // autocommit on its own, and the backstop runs outside any
      // transaction of its own: a process killed between two groups of
      // one dive leaves the rest unwritten, and two groups of the same
      // (dive, computer) differ only below the granularity the residue
      // count checks, so the survivors would read as covered and v183
      // would drop the legacy table with the missing group still only
      // in it. All of a dive's groups land, or none do.
      final before = (
        profileSeries: profileSeries,
        dropped: dropped,
        skipped: skipped,
        skippedRows: skippedRows,
      );
      try {
        await db.transaction(() async {
          // Ordered by timestamp alone: the map below does the grouping, and
          // ordering by the identity columns first would interleave two raw
          // groups that resolve to one key (a dangling computer id merging into
          // the null-computer group) out of timestamp order.
          final rows = await db
              .customSelect(
                'SELECT * FROM $profileTable WHERE dive_id = ? '
                'ORDER BY timestamp, rowid',
                variables: [Variable<String>(diveId)],
              )
              .get();
          final groups = <_ProfileKey, List<ProfileSample>>{};
          for (final row in rows) {
            final sample = profileSampleOf(row.data);
            if (sample == null) {
              skippedRows++;
              continue;
            }
            final key = _ProfileKey(
              computerId: _resolvedParent(row.data['computer_id'], computerIds),
              sourceId: _resolvedParent(row.data['source_id'], sourceIds),
              isPrimary: hasPrimary ? _boolOf(row.data['is_primary']) : true,
            );
            groups.putIfAbsent(key, () => []).add(sample);
          }
          for (final entry in groups.entries) {
            if (!diveIds.contains(diveId)) {
              skipped++;
              continue;
            }
            final key = entry.key;
            if (coveredProfiles.contains((diveId, key.computerId))) {
              // Already packed under this identity; the stored series wins.
              continue;
            }
            final samples = dedupeExactSamples(entry.value);
            dropped += entry.value.length - samples.length;
            final encoded = codec.encode(samples);
            final summary = encoded.summary;
            final inserted = await db.customUpdate(
              'INSERT OR IGNORE INTO dive_profile_series ('
              'id, dive_id, computer_id, source_id, is_primary, sample_count, '
              'start_timestamp, end_timestamp, max_depth, first_depth, last_depth, '
              'has_deco_type, has_deco_stop, has_positive_ceiling, codec_version, '
              'samples, created_at, updated_at, hlc) '
              'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
              variables: [
                Variable<String>(
                  profileSeriesMigratedId(
                    diveId: diveId,
                    computerId: key.computerId,
                    sourceId: key.sourceId,
                    isPrimary: key.isPrimary,
                  ),
                ),
                Variable<String>(diveId),
                Variable<String>(key.computerId),
                Variable<String>(key.sourceId),
                Variable<int>(key.isPrimary ? 1 : 0),
                Variable<int>(summary.sampleCount),
                Variable<int>(summary.startTimestamp),
                Variable<int>(summary.endTimestamp),
                Variable<double>(summary.maxDepth),
                Variable<double>(summary.firstDepth),
                Variable<double>(summary.lastDepth),
                Variable<int>(summary.hasDecoType ? 1 : 0),
                Variable<int>(summary.hasDecoStop ? 1 : 0),
                Variable<int>(summary.hasPositiveCeiling ? 1 : 0),
                Variable<int>(encoded.codecVersion),
                Variable<Uint8List>(encoded.bytes),
                Variable<int>(now),
                Variable<int>(now),
                Variable<String>(hlc),
              ],
              updateKind: UpdateKind.insert,
            );
            profileSeries += inserted;
          }
        });
      } catch (_) {
        // The dive rolled back, so its partial counts did not happen.
        profileSeries = before.profileSeries;
        dropped = before.dropped;
        skipped = before.skipped;
        skippedRows = before.skippedRows;
        // One dive at a time. A legacy value no reader expects (a text
        // depth in a REAL column, from a hand-repaired or bit-rotted file)
        // or a group the codec refuses must not cost the dives the scan
        // has not reached yet: nothing reads the legacy tables after v183,
        // so those would be a silent permanent loss rather than a retry.
        // The residue count keeps the legacy table, so a later open tries
        // this dive again.
        failedDives++;
      }
    }
  }
  if (profileSeries > 0) {
    // Raw SQL bypasses Drift's own change tracking, so a stream built on
    // `tableUpdates(TableUpdateQuery.onTable(db.diveProfileSeries))` would
    // otherwise never fire for a table this function just populated.
    db.notifyUpdates({
      const TableUpdate('dive_profile_series', kind: UpdateKind.insert),
    });
  }

  if (canPackTanks) {
    const codec = TankPressureSeriesCodec();
    for (final diveId in unpackedTankDives) {
      // One transaction per dive. Each group's INSERT would otherwise
      // autocommit on its own, and the backstop runs outside any
      // transaction of its own: a process killed between two groups of
      // one dive leaves the rest unwritten, and two groups of the same
      // (dive, computer) differ only below the granularity the residue
      // count checks, so the survivors would read as covered and v183
      // would drop the legacy table with the missing group still only
      // in it. All of a dive's groups land, or none do.
      final before = (
        tankSeries: tankSeries,
        dropped: dropped,
        skipped: skipped,
        skippedRows: skippedRows,
      );
      try {
        await db.transaction(() async {
          final rows = await db
              .customSelect(
                'SELECT * FROM $tankTable WHERE dive_id = ? '
                'ORDER BY timestamp, rowid',
                variables: [Variable<String>(diveId)],
              )
              .get();
          final groups = <_TankKey, List<TankPressureSample>>{};
          for (final row in rows) {
            final tankId = row.data['tank_id'] as String?;
            final timestamp = row.data['timestamp'] as num?;
            final pressure = row.data['pressure'] as num?;
            if (tankId == null || timestamp == null || pressure == null) {
              skippedRows++;
              continue;
            }
            final key = _TankKey(
              tankId: tankId,
              computerId: _resolvedParent(row.data['computer_id'], computerIds),
            );
            groups
                .putIfAbsent(key, () => [])
                .add(
                  TankPressureSample(
                    timestamp: timestamp.toInt(),
                    pressure: pressure.toDouble(),
                  ),
                );
          }
          for (final entry in groups.entries) {
            final key = entry.key;
            if (!diveIds.contains(diveId) || !tankIds.contains(key.tankId)) {
              skipped++;
              continue;
            }
            if (coveredTanks.contains((diveId, key.tankId, key.computerId))) {
              continue;
            }
            final samples = dedupeExactPressureSamples(entry.value);
            dropped += entry.value.length - samples.length;
            final encoded = codec.encode(samples);
            final inserted = await db.customUpdate(
              'INSERT OR IGNORE INTO tank_pressure_series ('
              'id, dive_id, tank_id, computer_id, sample_count, start_timestamp, '
              'end_timestamp, codec_version, samples, created_at, updated_at, hlc) '
              'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
              variables: [
                Variable<String>(
                  tankPressureSeriesMigratedId(
                    diveId: diveId,
                    tankId: key.tankId,
                    computerId: key.computerId,
                  ),
                ),
                Variable<String>(diveId),
                Variable<String>(key.tankId),
                Variable<String>(key.computerId),
                Variable<int>(encoded.summary.sampleCount),
                Variable<int>(encoded.summary.startTimestamp),
                Variable<int>(encoded.summary.endTimestamp),
                Variable<int>(encoded.codecVersion),
                Variable<Uint8List>(encoded.bytes),
                Variable<int>(now),
                Variable<int>(now),
                Variable<String>(hlc),
              ],
              updateKind: UpdateKind.insert,
            );
            tankSeries += inserted;
          }
        });
      } catch (_) {
        // The dive rolled back, so its partial counts did not happen.
        tankSeries = before.tankSeries;
        dropped = before.dropped;
        skipped = before.skipped;
        skippedRows = before.skippedRows;
        // One dive at a time. A legacy value no reader expects (a text
        // depth in a REAL column, from a hand-repaired or bit-rotted file)
        // or a group the codec refuses must not cost the dives the scan
        // has not reached yet: nothing reads the legacy tables after v183,
        // so those would be a silent permanent loss rather than a retry.
        // The residue count keeps the legacy table, so a later open tries
        // this dive again.
        failedDives++;
      }
    }
  }
  if (tankSeries > 0) {
    db.notifyUpdates({
      const TableUpdate('tank_pressure_series', kind: UpdateKind.insert),
    });
  }

  return (
    profileSeries: profileSeries,
    tankSeries: tankSeries,
    droppedSamples: dropped,
    skippedOrphans: skipped,
    skippedRows: skippedRows,
    failedDives: failedDives,
    skippedAlreadyPacked: alreadyPacked,
  );
}

/// Legacy rows still waiting to be packed, per legacy table.
typedef LegacyPackResidue = ({int profiles, int tanks});

/// How many rows each legacy table still holds that the pack should have
/// moved into the series tables and did not.
///
/// This is the gate on dropping a legacy table. [packLegacyProfileRows]
/// never deletes what it packs, so "is the legacy table empty" cannot be
/// the question; the question is whether a series row now covers every
/// legacy row that could ever become one. Three reachable ways the pack
/// leaves a row behind while returning normally, all of which this counts:
/// a pressure row whose tank is gone is skipped as an orphan; a dive that
/// already had a series row is never revisited, so a second computer's
/// legacy rows are never packed; and every insert is `INSERT OR IGNORE`, so
/// a series table shaped differently by a parallel branch can pack nothing
/// at all.
///
/// Coverage is checked per (dive, computer) for profiles and per (dive,
/// tank, computer) for tanks, resolving a dangling computer id to null the
/// way the packer's own grouping does. Finer identity terms (`source_id`,
/// `is_primary`) are deliberately left out: the pack works per dive, so
/// partialness below the computer level can only come from an ignored
/// insert, and gating on it would keep a table for a difference no read
/// ever sees.
///
/// A row that can NEVER be packed does not count, or the table would be
/// kept forever and its pages never reclaimed: a row with no timestamp,
/// depth, or pressure holds no sample, and a row whose dive is gone could
/// never have been rendered. A row whose tank is gone DOES count: the dive
/// is still the diver's, and those bytes are the only copy left.
Future<LegacyPackResidue> countLegacyRowsAwaitingPack(
  DatabaseConnectionUser db, {
  String profileTable = 'dive_profiles',
  String tankTable = 'tank_pressure_profiles',
}) async => (
  profiles: await _countUnpackedProfileRows(db, profileTable),
  tanks: await _countUnpackedTankRows(db, tankTable),
);

Future<int> _countUnpackedProfileRows(
  DatabaseConnectionUser db,
  String table,
) async {
  final columns = await _columnNames(db, table);
  if (columns.isEmpty) return 0;
  // A shape the packer cannot read, a missing series table, or a missing
  // `dives` table all mean nothing moved: every row is still only here.
  if (!columns.containsAll(const {'dive_id', 'timestamp', 'depth'}) ||
      !await _tableExists(db, 'dive_profile_series') ||
      !await _tableExists(db, 'dives')) {
    return _countRows(db, table);
  }
  final covered = await legacyRowCoveredSql(
    db,
    legacyTable: table,
    seriesTable: 'dive_profile_series',
    byTank: false,
  );
  final rows = await db
      .customSelect(
        'SELECT COUNT(*) AS n FROM $table p WHERE p.timestamp IS NOT NULL '
        'AND p.depth IS NOT NULL '
        'AND EXISTS (SELECT 1 FROM dives d WHERE d.id = p.dive_id) '
        'AND NOT $covered',
      )
      .getSingle();
  return rows.read<int>('n');
}

Future<int> _countUnpackedTankRows(
  DatabaseConnectionUser db,
  String table,
) async {
  final columns = await _columnNames(db, table);
  if (columns.isEmpty) return 0;
  if (!columns.containsAll(const {
        'dive_id',
        'tank_id',
        'timestamp',
        'pressure',
      }) ||
      !await _tableExists(db, 'tank_pressure_series') ||
      !await _tableExists(db, 'dives')) {
    return _countRows(db, table);
  }
  final covered = await legacyRowCoveredSql(
    db,
    legacyTable: table,
    seriesTable: 'tank_pressure_series',
    byTank: true,
  );
  final rows = await db
      .customSelect(
        'SELECT COUNT(*) AS n FROM $table p WHERE p.timestamp IS NOT NULL '
        'AND p.pressure IS NOT NULL AND p.tank_id IS NOT NULL '
        'AND EXISTS (SELECT 1 FROM dives d WHERE d.id = p.dive_id) '
        'AND NOT $covered',
      )
      .getSingle();
  return rows.read<int>('n');
}

/// Re-points pressure rows whose tank id is no longer one of the dive's
/// tanks at a tank that is, in place, before anything is packed.
///
/// `tank_pressure_series.tank_id` is a NOT NULL foreign key, so an orphan
/// cannot be packed as it stands, and after v183 every reader reads series:
/// leaving it behind drops that dive's pressure curve and per-cylinder SAC,
/// and its rows keep the legacy table alive forever, since the residue
/// count can never cover a tank that does not exist.
///
/// The rule is the v102 rung's ([AppDatabase] `_relinkStrandedTankPressures`)
/// and `GasAnalysisService`'s read-time resolver, so a dive reads the same
/// before and after packing: exact id matches are left alone, and the
/// remaining orphans, in first-sample order, are paired with the dive's
/// still-unmatched tanks in tank order. Both sides are totally ordered
/// (ties broken by id) and every device runs it over the same rows, so two
/// devices packing the same logbook reach the same tank ids and the derived
/// series ids still converge.
///
/// Healing the rows rather than remapping in memory keeps everything
/// downstream, the coverage predicate and residue count included, working
/// on ids that exist. Idempotent: a second run finds no orphans.
Future<void> _adoptStrandedTankPressures(
  DatabaseConnectionUser db,
  String table,
) async {
  if (!await _tableExists(db, 'dive_tanks')) return;
  final tankColumns = await _columnNames(db, 'dive_tanks');
  if (!tankColumns.containsAll(const {'id', 'dive_id'})) return;
  final hasOrder = tankColumns.contains('tank_order');
  final tankRows = await db
      .customSelect(
        'SELECT dive_id, id${hasOrder ? ', tank_order' : ''} FROM dive_tanks',
      )
      .get();
  final tanksByDive = <String, List<({String id, int order})>>{};
  for (final r in tankRows) {
    (tanksByDive[r.read<String>('dive_id')] ??= []).add((
      id: r.read<String>('id'),
      order: hasOrder ? (r.readNullable<int>('tank_order') ?? 0) : 0,
    ));
  }
  if (tanksByDive.isEmpty) return;

  final keyRows = await db
      .customSelect(
        'SELECT dive_id, tank_id, MIN(timestamp) AS first_ts FROM $table '
        'WHERE tank_id IS NOT NULL AND timestamp IS NOT NULL '
        'GROUP BY dive_id, tank_id',
      )
      .get();
  final keysByDive = <String, List<({String tankId, int firstTs})>>{};
  for (final r in keyRows) {
    (keysByDive[r.read<String>('dive_id')] ??= []).add((
      tankId: r.read<String>('tank_id'),
      firstTs: r.read<int>('first_ts'),
    ));
  }

  for (final entry in keysByDive.entries) {
    final diveId = entry.key;
    final tanks = tanksByDive[diveId];
    if (tanks == null || tanks.isEmpty) continue;
    final currentIds = {for (final t in tanks) t.id};
    final matchedIds = {
      for (final k in entry.value)
        if (currentIds.contains(k.tankId)) k.tankId,
    };
    final orphans =
        [
          for (final k in entry.value)
            if (!currentIds.contains(k.tankId)) k,
        ]..sort((a, b) {
          final byTime = a.firstTs.compareTo(b.firstTs);
          return byTime != 0 ? byTime : a.tankId.compareTo(b.tankId);
        });
    if (orphans.isEmpty) continue;
    final free =
        [
          for (final t in tanks)
            if (!matchedIds.contains(t.id)) t,
        ]..sort((a, b) {
          // id tie-break: tanks sharing the default order must still pair
          // deterministically, and Dart's sort is not stable.
          final byOrder = a.order.compareTo(b.order);
          return byOrder != 0 ? byOrder : a.id.compareTo(b.id);
        });
    final pairs = orphans.length < free.length ? orphans.length : free.length;
    for (var i = 0; i < pairs; i++) {
      await db.customStatement(
        'UPDATE $table SET tank_id = ? WHERE dive_id = ? AND tank_id = ?',
        [free[i].id, diveId, orphans[i].tankId],
      );
    }
  }
}

/// SQL predicate: the legacy row aliased `p` is already represented by a
/// row of [seriesTable].
///
/// Identity, not dive. A dive can be half packed: this device holds a series
/// for one computer while a peer below v183 still publishes row-per-sample
/// rows for the same dive from two. Asking "does this dive have a series"
/// would call the second computer's rows done and, on the staging path where
/// the staged rows are the only copy, discard them.
///
/// The identity is `(dive, computer)` for profiles and `(dive, tank,
/// computer)` for pressures, resolving a dangling computer id to null the
/// way the packer's own grouping does. Finer terms (`source_id`,
/// `is_primary`) are deliberately left out, matching what gates dropping a
/// legacy table: a difference below the computer level can only come from an
/// ignored insert, and acting on it would pack a second series for an
/// identity a read already resolves.
Future<String> legacyRowCoveredSql(
  DatabaseConnectionUser db, {
  required String legacyTable,
  required String seriesTable,
  required bool byTank,
}) async {
  final columns = await _columnNames(db, legacyTable);
  final computer = columns.contains('computer_id')
      ? 'AND s.computer_id IS ${await _resolvedComputerSql(db)}'
      : '';
  final tank = byTank ? 'AND s.tank_id = p.tank_id' : '';
  return 'EXISTS (SELECT 1 FROM $seriesTable s '
      'WHERE s.dive_id = p.dive_id $tank $computer)';
}

/// The scalar subquery that mirrors [_resolvedParent] for `computer_id`: the
/// legacy row's computer when it still names a `dive_computers` row, null
/// otherwise. Null too when the parent table itself is gone, which is what
/// the packer's empty parent set resolves every id to.
Future<String> _resolvedComputerSql(DatabaseConnectionUser db) async =>
    await _tableExists(db, 'dive_computers')
    ? '(SELECT c.id FROM dive_computers c WHERE c.id = p.computer_id)'
    : 'NULL';

Future<int> _countRows(DatabaseConnectionUser db, String table) async {
  final rows = await db
      .customSelect('SELECT COUNT(*) AS n FROM $table')
      .getSingle();
  return rows.read<int>('n');
}

class _ProfileKey {
  const _ProfileKey({
    required this.computerId,
    required this.sourceId,
    required this.isPrimary,
  });

  final String? computerId;
  final String? sourceId;
  final bool isPrimary;

  @override
  bool operator ==(Object other) =>
      other is _ProfileKey &&
      other.computerId == computerId &&
      other.sourceId == sourceId &&
      other.isPrimary == isPrimary;

  @override
  int get hashCode => Object.hash(computerId, sourceId, isPrimary);
}

class _TankKey {
  const _TankKey({required this.tankId, required this.computerId});

  final String tankId;
  final String? computerId;

  @override
  bool operator ==(Object other) =>
      other is _TankKey &&
      other.tankId == tankId &&
      other.computerId == computerId;

  @override
  int get hashCode => Object.hash(tankId, computerId);
}

Future<bool> _tableExists(DatabaseConnectionUser db, String table) async {
  final rows = await db
      .customSelect(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        variables: [Variable<String>(table)],
      )
      .get();
  return rows.isNotEmpty;
}

/// Every dive with legacy rows, split into the ones still to pack and a
/// count of the ones a series row already covers.
typedef _LegacyDiveScan = ({List<String> unpacked, int alreadyPacked});

const _LegacyDiveScan _emptyScan = (unpacked: <String>[], alreadyPacked: 0);

/// One pass over [legacyTable]'s distinct dive ids, marking each with
/// whether [seriesTable] already holds a row for it. Cheap once a database
/// is packed (an indexed EXISTS per legacy dive), which is what lets the
/// beforeOpen backstop call the packer on every open. Empty when the series
/// table is absent: `_assertProfileSeriesSchema` waits for that table's
/// foreign-key parents, so there is nothing to pack into yet.
///
/// The already-packed side is what feeds
/// [ProfilePackReport.skippedAlreadyPacked], and it comes from this same
/// scan rather than a second COUNT so the per-open cost does not change.
Future<_LegacyDiveScan> _scanLegacyDives(
  DatabaseConnectionUser db, {
  required String legacyTable,
  required String seriesTable,
  required bool byTank,
}) async {
  if (!await _tableExists(db, seriesTable)) return _emptyScan;
  final covered = await legacyRowCoveredSql(
    db,
    legacyTable: legacyTable,
    seriesTable: seriesTable,
    byTank: byTank,
  );
  // A dive is done only when EVERY one of its legacy rows is covered, hence
  // MIN over the per-row predicate. Testing the dive alone would leave a
  // second computer's rows unpacked forever on a half-packed dive.
  final rows = await db
      .customSelect(
        'SELECT p.dive_id AS dive_id, '
        'MIN(CASE WHEN $covered THEN 1 ELSE 0 END) AS all_covered '
        'FROM $legacyTable p GROUP BY p.dive_id ORDER BY p.dive_id',
      )
      .get();
  final unpacked = <String>[];
  var alreadyPacked = 0;
  for (final row in rows) {
    if (row.read<int>('all_covered') != 0) {
      alreadyPacked++;
    } else {
      unpacked.add(row.read<String>('dive_id'));
    }
  }
  return (unpacked: unpacked, alreadyPacked: alreadyPacked);
}

/// The `(dive, computer)` identities `dive_profile_series` already holds.
Future<Set<(String, String?)>> _coveredProfileIdentities(
  DatabaseConnectionUser db,
) async {
  if (!await _tableExists(db, 'dive_profile_series')) return const {};
  final rows = await db
      .customSelect('SELECT dive_id, computer_id FROM dive_profile_series')
      .get();
  return {
    for (final r in rows)
      (r.read<String>('dive_id'), r.readNullable<String>('computer_id')),
  };
}

/// The `(dive, tank, computer)` identities `tank_pressure_series` holds.
Future<Set<(String, String, String?)>> _coveredTankIdentities(
  DatabaseConnectionUser db,
) async {
  if (!await _tableExists(db, 'tank_pressure_series')) return const {};
  final rows = await db
      .customSelect(
        'SELECT dive_id, tank_id, computer_id FROM tank_pressure_series',
      )
      .get();
  return {
    for (final r in rows)
      (
        r.read<String>('dive_id'),
        r.read<String>('tank_id'),
        r.readNullable<String>('computer_id'),
      ),
  };
}

/// Every id in [table], or an empty set when the table is absent. Loaded
/// once per run so the per-group parent checks below cost nothing.
Future<Set<String>> _parentIds(DatabaseConnectionUser db, String table) async {
  if (!await _tableExists(db, table)) return const {};
  final rows = await db.customSelect('SELECT id FROM $table').get();
  return {for (final row in rows) row.read<String>('id')};
}

/// The column names of [table], empty when the table does not exist.
Future<Set<String>> _columnNames(
  DatabaseConnectionUser db,
  String table,
) async {
  final rows = await db.customSelect("PRAGMA table_info('$table')").get();
  return {for (final row in rows) row.read<String>('name')};
}

/// [value] when it still names a row in [parents], null otherwise. A legacy
/// row can point at a computer or source that has since been deleted, which
/// under `PRAGMA foreign_keys = ON` no insert could carry.
String? _resolvedParent(Object? value, Set<String> parents) {
  final id = value as String?;
  return id != null && parents.contains(id) ? id : null;
}

/// The clock value migrated rows carry. Null when this device has never
/// synced: there is no device id to stamp with, and nothing to publish to.
Future<String?> _migrationHlc(DatabaseConnectionUser db, int nowMs) async {
  if (!await _tableExists(db, 'sync_metadata')) return null;
  final rows = await db
      .customSelect("SELECT * FROM sync_metadata WHERE id = 'global' LIMIT 1")
      .get();
  if (rows.isEmpty) return null;
  final deviceId = rows.first.data['device_id'] as String?;
  if (deviceId == null || deviceId.isEmpty) return null;
  // Advance the persisted clock rather than minting from wall-clock time:
  // a peer merge can have moved this device's clock ahead of now, and a
  // stamp below the publish watermark would never ride a changeset.
  final persisted = rows.first.data['hlc'] as String?;
  if (persisted != null && persisted.isNotEmpty) {
    try {
      final advanced = Hlc.parse(persisted).increment(nowMs);
      // The device id column is the authority on this device's node id.
      return Hlc(advanced.physicalTime, advanced.counter, deviceId).toString();
    } on FormatException {
      // Fall through to a fresh clock.
    }
  }
  return Hlc(nowMs, 0, deviceId).toString();
}

bool _boolOf(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  // Every legacy schema declares is_primary NOT NULL DEFAULT 1, so a null
  // here means the column is not carrying a value at all; a legacy row with
  // no flag is the dive's live profile, which is what true says.
  return true;
}
