import 'package:drift/drift.dart';
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
});

/// Packs every legacy `dive_profiles` and `tank_pressure_profiles` row into
/// the series tables (v182, spec 2026-08-28-profile-sample-storage).
///
/// Raw SQL throughout, never the legacy Drift classes: plan 2e removes those
/// classes and drops the tables, and this function must keep compiling and
/// keep no-oping on a database that has already lost them.
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
Future<ProfilePackReport> packLegacyProfileRows(
  DatabaseConnectionUser db, {
  int? nowMs,
}) async {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final hlc = await _migrationHlc(db, now);
  final diveIds = await _parentIds(db, 'dives');
  final computerIds = await _parentIds(db, 'dive_computers');
  final sourceIds = await _parentIds(db, 'dive_data_sources');
  final tankIds = await _parentIds(db, 'dive_tanks');
  var profileSeries = 0;
  var tankSeries = 0;
  var dropped = 0;
  var skipped = 0;

  final profileColumns = await _columnNames(db, 'dive_profiles');
  if (profileColumns.containsAll(const {'dive_id', 'timestamp', 'depth'})) {
    const codec = ProfileSeriesCodec();
    final hasPrimary = profileColumns.contains('is_primary');
    final unpacked = await _unpackedDiveIds(
      db,
      legacyTable: 'dive_profiles',
      seriesTable: 'dive_profile_series',
    );
    for (final diveId in unpacked) {
      // Ordered by timestamp alone: the map below does the grouping, and
      // ordering by the identity columns first would interleave two raw
      // groups that resolve to one key (a dangling computer id merging into
      // the null-computer group) out of timestamp order.
      final rows = await db
          .customSelect(
            'SELECT * FROM dive_profiles WHERE dive_id = ? '
            'ORDER BY timestamp, rowid',
            variables: [Variable<String>(diveId)],
          )
          .get();
      final groups = <_ProfileKey, List<ProfileSample>>{};
      for (final row in rows) {
        final key = _ProfileKey(
          computerId: _resolvedParent(row.data['computer_id'], computerIds),
          sourceId: _resolvedParent(row.data['source_id'], sourceIds),
          isPrimary: hasPrimary ? _boolOf(row.data['is_primary']) : true,
        );
        groups.putIfAbsent(key, () => []).add(_profileSampleOf(row.data));
      }
      for (final entry in groups.entries) {
        if (!diveIds.contains(diveId)) {
          skipped++;
          continue;
        }
        final key = entry.key;
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
    }
  }

  final tankColumns = await _columnNames(db, 'tank_pressure_profiles');
  if (tankColumns.containsAll(const {
    'dive_id',
    'tank_id',
    'timestamp',
    'pressure',
  })) {
    const codec = TankPressureSeriesCodec();
    final unpacked = await _unpackedDiveIds(
      db,
      legacyTable: 'tank_pressure_profiles',
      seriesTable: 'tank_pressure_series',
    );
    for (final diveId in unpacked) {
      final rows = await db
          .customSelect(
            'SELECT * FROM tank_pressure_profiles WHERE dive_id = ? '
            'ORDER BY timestamp, rowid',
            variables: [Variable<String>(diveId)],
          )
          .get();
      final groups = <_TankKey, List<TankPressureSample>>{};
      for (final row in rows) {
        final key = _TankKey(
          tankId: row.data['tank_id'] as String,
          computerId: _resolvedParent(row.data['computer_id'], computerIds),
        );
        groups
            .putIfAbsent(key, () => [])
            .add(
              TankPressureSample(
                timestamp: (row.data['timestamp'] as num).toInt(),
                pressure: (row.data['pressure'] as num).toDouble(),
              ),
            );
      }
      for (final entry in groups.entries) {
        final key = entry.key;
        if (!diveIds.contains(diveId) || !tankIds.contains(key.tankId)) {
          skipped++;
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
    }
  }

  return (
    profileSeries: profileSeries,
    tankSeries: tankSeries,
    droppedSamples: dropped,
    skippedOrphans: skipped,
  );
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

/// Dives that still have legacy rows and no series rows yet. Cheap once a
/// database is packed (an indexed NOT EXISTS per legacy dive), which is what
/// lets the beforeOpen backstop call the packer on every open. Empty when
/// the series table is absent: `_assertProfileSeriesSchema` waits for that
/// table's foreign-key parents, so there is nothing to pack into yet.
Future<List<String>> _unpackedDiveIds(
  DatabaseConnectionUser db, {
  required String legacyTable,
  required String seriesTable,
}) async {
  if (!await _tableExists(db, seriesTable)) return const [];
  final rows = await db
      .customSelect(
        'SELECT DISTINCT p.dive_id AS dive_id FROM $legacyTable p '
        'WHERE NOT EXISTS (SELECT 1 FROM $seriesTable s '
        'WHERE s.dive_id = p.dive_id) ORDER BY p.dive_id',
      )
      .get();
  return [for (final row in rows) row.read<String>('dive_id')];
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
      return Hlc.parse(persisted).increment(nowMs).toString();
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

double? _realOf(Object? value) => (value as num?)?.toDouble();

int? _intOf(Object? value) => (value as num?)?.toInt();

/// Reads a legacy `dive_profiles` row by column name. Absent columns (an
/// older fixture or a partially migrated table) read as null.
ProfileSample _profileSampleOf(Map<String, Object?> data) {
  return ProfileSample(
    timestamp: (data['timestamp'] as num).toInt(),
    depth: (data['depth'] as num).toDouble(),
    pressure: _realOf(data['pressure']),
    temperature: _realOf(data['temperature']),
    heartRate: _intOf(data['heart_rate']),
    ascentRate: _realOf(data['ascent_rate']),
    ceiling: _realOf(data['ceiling']),
    ndl: _intOf(data['ndl']),
    setpoint: _realOf(data['setpoint']),
    ppO2: _realOf(data['pp_o2']),
    o2Sensor1: _realOf(data['o2_sensor1']),
    o2Sensor2: _realOf(data['o2_sensor2']),
    o2Sensor3: _realOf(data['o2_sensor3']),
    o2Sensor4: _realOf(data['o2_sensor4']),
    o2Sensor5: _realOf(data['o2_sensor5']),
    o2Sensor6: _realOf(data['o2_sensor6']),
    cns: _realOf(data['cns']),
    tts: _intOf(data['tts']),
    rbt: _intOf(data['rbt']),
    decoType: _intOf(data['deco_type']),
    heartRateSource: data['heart_rate_source'] as String?,
    heading: _realOf(data['heading']),
    o2SensorMv1: _intOf(data['o2_sensor_mv1']),
    o2SensorMv2: _intOf(data['o2_sensor_mv2']),
    o2SensorMv3: _intOf(data['o2_sensor_mv3']),
    o2SensorMv4: _intOf(data['o2_sensor_mv4']),
    o2SensorMv5: _intOf(data['o2_sensor_mv5']),
    o2SensorMv6: _intOf(data['o2_sensor_mv6']),
  );
}
