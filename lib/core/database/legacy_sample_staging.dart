import 'package:drift/drift.dart';

import 'package:submersion/core/database/profile_series_pack.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_field_table.dart';

/// Where an older peer's row-per-sample arrays land now that the legacy
/// tables are gone (v183). TEMP tables live for the connection; the packer
/// reads them like it read `dive_profiles`, and they are emptied after each
/// pack. Retire with the receive-side shim (plan 2d's
/// SyncService.inboundOnlyLegacyEntities) once no peer below 182 can publish.
const String kLegacyProfileStagingTable = 'dive_profiles_inbound';
const String kLegacyTankStagingTable = 'tank_pressure_profiles_inbound';

String _sqlType(ProfileFieldKind kind) => switch (kind) {
  ProfileFieldKind.deltaInt => 'INTEGER',
  ProfileFieldKind.float64 => 'REAL',
  ProfileFieldKind.runLengthString => 'TEXT',
};

/// The legacy `dive_profiles` columns: identity plus every codec field.
final List<String> _legacyProfileColumns = [
  'id',
  'dive_id',
  'computer_id',
  'source_id',
  'is_primary',
  for (final f in kProfileFieldTableV1) f.name,
];

const List<String> _legacyTankColumns = [
  'id',
  'dive_id',
  'tank_id',
  'computer_id',
  'timestamp',
  'pressure',
];

String _profileDdl() =>
    'CREATE TEMP TABLE IF NOT EXISTS $kLegacyProfileStagingTable ('
    'id TEXT NOT NULL PRIMARY KEY, dive_id TEXT NOT NULL, computer_id TEXT, '
    'source_id TEXT, is_primary INTEGER NOT NULL DEFAULT 1, '
    '${[for (final f in kProfileFieldTableV1) '${f.name} ${_sqlType(f.kind)}'].join(', ')})';

const String _tankDdl =
    'CREATE TEMP TABLE IF NOT EXISTS $kLegacyTankStagingTable ('
    'id TEXT NOT NULL PRIMARY KEY, dive_id TEXT NOT NULL, tank_id TEXT NOT NULL, '
    'computer_id TEXT, timestamp INTEGER NOT NULL, pressure REAL NOT NULL)';

Future<void> ensureLegacyStagingTables(DatabaseConnectionUser db) async {
  await db.customStatement(_profileDdl());
  await db.customStatement(_tankDdl);
}

/// `diveId` -> `dive_id`, `ppO2` -> `pp_o2`, `o2SensorMv1` -> `o2_sensor_mv1`:
/// Drift's default column naming, which is what the wire keys were made from.
String legacyColumnFor(String wireKey) =>
    wireKey.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');

Future<int> stageLegacyProfileRows(
  DatabaseConnectionUser db,
  List<Map<String, dynamic>> jsonRows,
) => _stage(db, kLegacyProfileStagingTable, _legacyProfileColumns, jsonRows);

Future<int> stageLegacyTankRows(
  DatabaseConnectionUser db,
  List<Map<String, dynamic>> jsonRows,
) => _stage(db, kLegacyTankStagingTable, _legacyTankColumns, jsonRows);

Future<int> _stage(
  DatabaseConnectionUser db,
  String table,
  List<String> columns,
  List<Map<String, dynamic>> jsonRows,
) async {
  var staged = 0;
  for (final row in jsonRows) {
    final values = <String, Object?>{};
    for (final entry in row.entries) {
      final column = legacyColumnFor(entry.key);
      if (!columns.contains(column)) continue;
      final v = entry.value;
      values[column] = v is bool ? (v ? 1 : 0) : v;
    }
    if (values['id'] == null || values['dive_id'] == null) continue;
    final names = values.keys.toList();
    await db.customStatement(
      'INSERT OR REPLACE INTO $table (${names.join(', ')}) '
      'VALUES (${List.filled(names.length, '?').join(', ')})',
      [for (final n in names) values[n]],
    );
    staged++;
  }
  return staged;
}

/// Packs whatever is staged into series (dives that already have a series
/// are left alone, exactly as the migration packer does) and empties both
/// staging tables.
///
/// The staging tables are emptied only after a successful pack. The TEMP
/// table is the only copy of a peer's row once staged (the real
/// `dive_profiles` / `tank_pressure_profiles` tables are gone), so if
/// [packLegacyProfileRows] throws, the rows are left staged rather than
/// discarded: the next apply in this session (another changeset, base file,
/// or adopt) calls this again and retries the same staged rows. A TEMP
/// table does not survive past this connection, so an app restart loses
/// whatever is still staged; recovery then is the origin peer republishing
/// its base or changeset, which stages the rows again.
Future<ProfilePackReport> packStagedLegacyRows(
  DatabaseConnectionUser db,
) async {
  await ensureLegacyStagingTables(db);
  final report = await packLegacyProfileRows(
    db,
    profileTable: kLegacyProfileStagingTable,
    tankTable: kLegacyTankStagingTable,
  );
  await db.customStatement('DELETE FROM $kLegacyProfileStagingTable');
  await db.customStatement('DELETE FROM $kLegacyTankStagingTable');
  return report;
}
