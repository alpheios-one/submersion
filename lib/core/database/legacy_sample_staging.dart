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

/// Columns whose value the staging DDL supplies when the wire row omits the
/// key. Only `is_primary` has a DDL default; binding null for it would fail
/// its NOT NULL constraint, which is what the old per-row column list
/// avoided by leaving the column out of the statement altogether.
const Map<String, Object?> _legacyProfileDefaults = {'is_primary': 1};

/// Rows per multi-row INSERT. SQLite's default SQLITE_MAX_VARIABLE_NUMBER is
/// 32,766. The wider of the two staging tables is the profile one, five
/// identity columns plus every codec field, so 200 rows binds well under
/// 7,000 values; [_maxStagedVariables] keeps that true if the field table
/// grows.
const int _maxStagedRowsPerStatement = 200;
const int _maxStagedVariables = 30000;

Future<int> stageLegacyProfileRows(
  DatabaseConnectionUser db,
  List<Map<String, dynamic>> jsonRows,
) => _stage(
  db,
  kLegacyProfileStagingTable,
  _legacyProfileColumns,
  jsonRows,
  defaults: _legacyProfileDefaults,
);

Future<int> stageLegacyTankRows(
  DatabaseConnectionUser db,
  List<Map<String, dynamic>> jsonRows,
) => _stage(db, kLegacyTankStagingTable, _legacyTankColumns, jsonRows);

/// Stages [jsonRows] into [table], returning how many rows were written.
///
/// Every row binds the SAME full [columns] list, so one statement shape
/// serves a whole chunk rather than a fresh SQL string per row. A key the
/// wire row omits binds its [defaults] entry, or null. Values are always
/// bound, never interpolated; only the identifiers come from the fixed
/// column and table constants above.
///
/// Chunked at [_maxStagedRowsPerStatement] rows per statement. A throw part
/// way through therefore leaves the earlier chunks staged, which is harmless:
/// the staging tables are TEMP and the pack that reads them is idempotent,
/// so the retry restages the same ids over the same rows
/// (`INSERT OR REPLACE`) and packs once.
///
/// [jsonRows] is only read; the caller's list and maps are never mutated.
Future<int> _stage(
  DatabaseConnectionUser db,
  String table,
  List<String> columns,
  List<Map<String, dynamic>> jsonRows, {
  Map<String, Object?> defaults = const {},
}) async {
  final staged = <List<Object?>>[];
  for (final row in jsonRows) {
    final values = <String, Object?>{};
    for (final entry in row.entries) {
      final column = legacyColumnFor(entry.key);
      if (!columns.contains(column)) continue;
      final v = entry.value;
      values[column] = v is bool ? (v ? 1 : 0) : v;
    }
    if (values['id'] == null || values['dive_id'] == null) continue;
    staged.add([
      for (final column in columns) values[column] ?? defaults[column],
    ]);
  }
  if (staged.isEmpty) return 0;

  final perStatement = _rowsPerStatement(columns.length);
  final tuple = '(${List.filled(columns.length, '?').join(', ')})';
  final prefix =
      'INSERT OR REPLACE INTO $table (${columns.join(', ')}) VALUES ';
  for (var start = 0; start < staged.length; start += perStatement) {
    final end = start + perStatement < staged.length
        ? start + perStatement
        : staged.length;
    final chunk = staged.sublist(start, end);
    await db.customStatement(
      prefix + List.filled(chunk.length, tuple).join(', '),
      [for (final row in chunk) ...row],
    );
  }
  return staged.length;
}

int _rowsPerStatement(int columnCount) {
  final byVariables = _maxStagedVariables ~/ columnCount;
  if (byVariables < 1) return 1;
  return byVariables < _maxStagedRowsPerStatement
      ? byVariables
      : _maxStagedRowsPerStatement;
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
