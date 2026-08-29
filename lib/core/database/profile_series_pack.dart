import 'package:drift/drift.dart';
import 'package:submersion/core/services/sync/hlc.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_sample.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_series_codec.dart';
import 'package:submersion/features/dive_log/domain/codecs/tank_pressure_series_codec.dart';
import 'package:submersion/features/dive_log/domain/entities/profile_series.dart';
import 'package:submersion/features/dive_log/domain/services/profile_sample_dedupe.dart';

/// What one packing pass inserted and dropped.
typedef ProfilePackReport = ({
  int profileSeries,
  int tankSeries,
  int droppedSamples,
});

/// Packs every legacy `dive_profiles` and `tank_pressure_profiles` row into
/// the series tables (v181, spec 2026-08-28-profile-sample-storage).
///
/// Raw SQL throughout, never the legacy Drift classes: plan 2e removes those
/// classes and drops the tables, and this function must keep compiling and
/// keep no-oping on a database that has already lost them.
///
/// Memory is bounded by one dive's rows, never the table. Each identity
/// group becomes one row whose id is derived from the tuple
/// ([profileSeriesMigratedId]), so a second run, a retry after a failed
/// ladder, or a second device migrating the same synced rows all converge:
/// the insert is `INSERT OR IGNORE`.
///
/// Exact duplicate samples (a repeated import) are dropped before packing,
/// which is what every read did on the way out until now.
///
/// [nowMs] stamps `created_at` and `updated_at`. `hlc` is minted from the
/// device id in `sync_metadata` when one exists, so the first sync after the
/// upgrade publishes the rows; a device that never synced has nothing to
/// publish to and its rows stay unstamped until a base publish, which
/// exports everything regardless.
Future<ProfilePackReport> packLegacyProfileRows(
  DatabaseConnectionUser db, {
  int? nowMs,
}) async {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final hlc = await _migrationHlc(db, now);
  var profileSeries = 0;
  var tankSeries = 0;
  var dropped = 0;

  if (await _tableExists(db, 'dive_profiles')) {
    const codec = ProfileSeriesCodec();
    for (final diveId in await _diveIds(db, 'dive_profiles')) {
      final rows = await db
          .customSelect(
            'SELECT * FROM dive_profiles WHERE dive_id = ? '
            'ORDER BY computer_id, source_id, is_primary, timestamp, rowid',
            variables: [Variable<String>(diveId)],
          )
          .get();
      final groups = <_ProfileKey, List<ProfileSample>>{};
      for (final row in rows) {
        final key = _ProfileKey(
          computerId: row.data['computer_id'] as String?,
          sourceId: row.data['source_id'] as String?,
          isPrimary: _boolOf(row.data['is_primary'], fallback: true),
        );
        groups.putIfAbsent(key, () => []).add(_profileSampleOf(row.data));
      }
      for (final entry in groups.entries) {
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

  if (await _tableExists(db, 'tank_pressure_profiles')) {
    const codec = TankPressureSeriesCodec();
    for (final diveId in await _diveIds(db, 'tank_pressure_profiles')) {
      final rows = await db
          .customSelect(
            'SELECT * FROM tank_pressure_profiles WHERE dive_id = ? '
            'ORDER BY tank_id, computer_id, timestamp, rowid',
            variables: [Variable<String>(diveId)],
          )
          .get();
      final groups = <_TankKey, List<TankPressureSample>>{};
      for (final row in rows) {
        final key = _TankKey(
          tankId: row.data['tank_id'] as String,
          computerId: row.data['computer_id'] as String?,
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

Future<List<String>> _diveIds(DatabaseConnectionUser db, String table) async {
  final rows = await db
      .customSelect('SELECT DISTINCT dive_id FROM $table ORDER BY dive_id')
      .get();
  return [for (final row in rows) row.read<String>('dive_id')];
}

/// The clock value migrated rows carry. Null when this device has never
/// synced: there is no device id to stamp with, and nothing to publish to.
Future<String?> _migrationHlc(DatabaseConnectionUser db, int nowMs) async {
  if (!await _tableExists(db, 'sync_metadata')) return null;
  final rows = await db
      .customSelect(
        "SELECT device_id FROM sync_metadata WHERE id = 'global' LIMIT 1",
      )
      .get();
  if (rows.isEmpty) return null;
  final deviceId = rows.first.readNullable<String>('device_id');
  if (deviceId == null || deviceId.isEmpty) return null;
  return Hlc(nowMs, 0, deviceId).toString();
}

bool _boolOf(Object? value, {required bool fallback}) {
  if (value == null) return fallback;
  if (value is bool) return value;
  if (value is num) return value != 0;
  return fallback;
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
