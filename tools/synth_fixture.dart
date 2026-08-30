import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// Replicates every dive of a plaintext Submersion database N times under
/// fresh ids so a small development library becomes a large benchmark
/// fixture. Usage:
///
///     dart run tools/synth_fixture.dart <source.db> <out.db> --replicas 25
///
/// Never points at a live database: it copies the source file first. Child
/// rows are found by column name: every table with a `dive_id` column is
/// replicated; `id` (when text) gets a `-r<k>` suffix, `dive_id`, `tank_id`
/// and `source_id` are remapped to the replica's ids, `computer_id`,
/// `site_id` and every other column are copied as they are. Media rows are
/// skipped (blob stores are not part of the profile benchmark).
void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln(
      'Usage: dart run tools/synth_fixture.dart <source.db> <out.db> '
      '[--replicas N]',
    );
    exit(64);
  }
  final source = args[0];
  final out = args[1];
  final replicas = args.contains('--replicas')
      ? int.parse(args[args.indexOf('--replicas') + 1])
      : 25;
  if (!File(source).existsSync()) {
    stderr.writeln('No such file: $source');
    exit(66);
  }
  File(source).copySync(out);
  final db = sqlite3.open(out);
  try {
    db.execute('PRAGMA foreign_keys = OFF');
    final tables = _tablesWithDiveId(db)..remove('media');
    final diveIds = db
        .select('SELECT id FROM dives')
        .map((r) => r['id'] as String)
        .toList();
    db.execute('BEGIN');
    for (var k = 1; k <= replicas; k++) {
      final suffix = '-r$k';
      for (final table in ['dives', ...tables.where((t) => t != 'dives')]) {
        _replicate(db, table, suffix, diveIds);
      }
    }
    db.execute('COMMIT');
    for (final table in ['dives', ...tables]) {
      final n = db.select('SELECT COUNT(*) AS n FROM $table').first['n'];
      stdout.writeln('$table: $n');
    }
  } finally {
    db.close();
  }
}

Set<String> _tablesWithDiveId(Database db) {
  final out = <String>{};
  for (final row in db.select(
    "SELECT name FROM sqlite_master WHERE type = 'table' "
    "AND name NOT LIKE 'sqlite_%'",
  )) {
    final name = row['name'] as String;
    final cols = db
        .select('SELECT name FROM pragma_table_info(?)', [name])
        .map((c) => c['name'] as String);
    if (cols.contains('dive_id')) out.add(name);
  }
  return out;
}

void _replicate(
  Database db,
  String table,
  String suffix,
  List<String> diveIds,
) {
  final cols = db
      .select('SELECT name FROM pragma_table_info(?)', [table])
      .map((c) => c['name'] as String)
      .toList();
  final names = cols;
  final where = table == 'dives'
      ? 'WHERE id IN (${List.filled(diveIds.length, '?').join(',')})'
      : 'WHERE dive_id IN (${List.filled(diveIds.length, '?').join(',')})';
  final rows = db.select(
    'SELECT ${names.join(', ')} FROM $table $where',
    diveIds,
  );
  final insert = db.prepare(
    'INSERT OR IGNORE INTO $table (${names.join(', ')}) '
    'VALUES (${List.filled(names.length, '?').join(', ')})',
  );
  try {
    for (final row in rows) {
      final values = <Object?>[];
      for (final name in cols) {
        final v = row[name];
        if (v is String &&
            (name == 'id' ||
                name == 'dive_id' ||
                name == 'tank_id' ||
                name == 'source_id')) {
          values.add('$v$suffix');
        } else {
          values.add(v);
        }
      }
      insert.execute(values);
    }
  } finally {
    insert.close();
  }
}
