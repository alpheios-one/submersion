import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/database.dart';

/// v177: the three GTR settings on diver_settings, plus a repair of
/// dive_profiles.rbt. libdivecomputer reports RBT/GTR in minutes but every
/// app path stored the raw value in a column documented as seconds, so rows
/// that came through libdc (the only ones with raw bytes on their data source)
/// are scaled by 60; file imports (Subsurface, UDDF) already wrote seconds and
/// are left alone.
NativeDatabase _dbAt176({void Function(dynamic rawDb)? seed}) {
  return NativeDatabase.memory(
    setup: (rawDb) {
      rawDb.execute('PRAGMA user_version = 176');
      rawDb.execute('''
        CREATE TABLE diver_settings (
          id TEXT NOT NULL PRIMARY KEY
        )
      ''');
      rawDb.execute("INSERT INTO diver_settings (id) VALUES ('settings')");
      rawDb.execute('''
        CREATE TABLE dive_data_sources (
          id TEXT NOT NULL PRIMARY KEY,
          dive_id TEXT NOT NULL,
          raw_data BLOB
        )
      ''');
      rawDb.execute('''
        CREATE TABLE dive_profiles (
          id TEXT NOT NULL PRIMARY KEY,
          dive_id TEXT NOT NULL,
          rbt INTEGER
        )
      ''');
      seed?.call(rawDb);
    },
  );
}

Future<Set<String>> _columns(AppDatabase db, String table) async {
  final cols = await db.customSelect("PRAGMA table_info('$table')").get();
  return cols.map((c) => c.read<String>('name')).toSet();
}

void main() {
  test('v177 adds the GTR settings columns with their defaults', () async {
    final db = AppDatabase(_dbAt176());
    addTearDown(db.close);

    final names = await _columns(db, 'diver_settings');
    expect(names, contains('default_show_gtr'));
    expect(names, contains('default_gtr_source'));
    expect(names, contains('gtr_reserve_pressure'));

    final row = await db
        .customSelect(
          'SELECT default_show_gtr, default_gtr_source, gtr_reserve_pressure '
          'FROM diver_settings',
        )
        .getSingle();
    expect(row.read<int>('default_show_gtr'), 0);
    expect(row.read<int>('default_gtr_source'), 1);
    expect(row.read<double>('gtr_reserve_pressure'), 50.0);
  });

  test('v177 scales libdc-sourced rbt from minutes to seconds', () async {
    final db = AppDatabase(
      _dbAt176(
        seed: (rawDb) {
          rawDb.execute(
            "INSERT INTO dive_data_sources VALUES ('s1', 'downloaded', ?)",
            [
              Uint8List.fromList([1, 2, 3]),
            ],
          );
          rawDb.execute(
            "INSERT INTO dive_data_sources VALUES ('s2', 'imported', NULL)",
          );
          rawDb.execute(
            "INSERT INTO dive_profiles VALUES "
            "('p1', 'downloaded', 25), "
            "('p2', 'downloaded', NULL), "
            "('p3', 'imported', 1500), "
            "('p4', 'orphan', 30)",
          );
        },
      ),
    );
    addTearDown(db.close);

    final rows = await db
        .customSelect('SELECT id, rbt FROM dive_profiles ORDER BY id')
        .get();
    final byId = {
      for (final r in rows) r.read<String>('id'): r.read<int?>('rbt'),
    };
    // Downloaded through libdc: 25 min becomes 1500 s.
    expect(byId['p1'], 1500);
    expect(byId['p2'], isNull);
    // Subsurface/UDDF import already wrote seconds.
    expect(byId['p3'], 1500);
    // No data source at all: nothing known about its origin, leave it.
    expect(byId['p4'], 30);
  });

  test('fresh databases get the GTR settings columns', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final names = await _columns(db, 'diver_settings');
    expect(names, contains('default_show_gtr'));
    expect(names, contains('default_gtr_source'));
    expect(names, contains('gtr_reserve_pressure'));
  });

  test('v177 is present in the migration ladder', () {
    expect(AppDatabase.currentSchemaVersion, greaterThanOrEqualTo(177));
    expect(AppDatabase.migrationVersions, contains(177));
  });
}
