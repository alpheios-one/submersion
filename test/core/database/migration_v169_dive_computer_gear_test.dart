import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/core/database/database.dart';

/// v169 adds `dive_computers.equipment_id`: the equipment row that represents a
/// registered computer as gear, so a downloaded dive lists the computer that
/// logged it alongside the rest of the diver's kit. Nullable with no default,
/// because a cleared value means the user deleted that gear item and it must
/// not come back.
const String _preV169DiveComputers = '''
  CREATE TABLE dive_computers (
    id TEXT NOT NULL PRIMARY KEY,
    diver_id TEXT,
    name TEXT NOT NULL,
    manufacturer TEXT,
    model TEXT,
    serial_number TEXT,
    dive_count INTEGER NOT NULL DEFAULT 0,
    is_favorite INTEGER NOT NULL DEFAULT 0,
    notes TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )
''';

NativeDatabase _dbAt168() {
  return NativeDatabase.memory(
    setup: (rawDb) {
      rawDb.execute('PRAGMA user_version = 168');
      rawDb.execute(_preV169DiveComputers);
      rawDb.execute(
        "INSERT INTO dive_computers (id, name, created_at, updated_at) "
        "VALUES ('c1', 'My Perdix', 1, 1)",
      );
    },
  );
}

void main() {
  test('v169 is in the migration ladder', () {
    expect(AppDatabase.currentSchemaVersion, greaterThanOrEqualTo(169));
    expect(AppDatabase.migrationVersions, contains(169));
  });

  test('a fresh database has dive_computers.equipment_id', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final cols = await db
        .customSelect("PRAGMA table_info('dive_computers')")
        .get();
    final names = cols.map((c) => c.read<String>('name')).toSet();
    expect(names, contains('equipment_id'));
  });

  test('the column is nullable and carries no default', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final cols = await db
        .customSelect("PRAGMA table_info('dive_computers')")
        .get();
    final column = cols.firstWhere(
      (c) => c.read<String>('name') == 'equipment_id',
    );
    // A non-null default would claim every registered computer already has a
    // gear item, and would resurrect one the user deleted.
    expect(column.read<int>('notnull'), 0);
    expect(column.read<String?>('dflt_value'), isNull);
  });

  test('a database at v168 gains the column and keeps its rows', () async {
    final db = AppDatabase(_dbAt168());
    addTearDown(db.close);

    final row = await db
        .customSelect(
          "SELECT name, equipment_id FROM dive_computers WHERE id = 'c1'",
        )
        .getSingle();
    expect(row.read<String>('name'), 'My Perdix');
    expect(row.read<String?>('equipment_id'), isNull);
  });

  test('a database stranded at a parallel-branch v169 gains the column via '
      'beforeOpen', () async {
    // Stamped AT 169 but without the column: the onUpgrade block never runs,
    // so only the beforeOpen backstop can add it.
    final nativeDb = NativeDatabase.memory(
      setup: (rawDb) {
        rawDb.execute('PRAGMA user_version = 169');
        rawDb.execute(_preV169DiveComputers);
      },
    );
    final db = AppDatabase(nativeDb);
    addTearDown(db.close);

    final cols = await db
        .customSelect("PRAGMA table_info('dive_computers')")
        .get();
    final names = cols.map((c) => c.read<String>('name')).toSet();
    expect(names, contains('equipment_id'));
  });
}
