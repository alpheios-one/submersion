import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/core/database/database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('v154 adds default cost columns, preserving rows', () async {
    final native = NativeDatabase.memory(
      setup: (db) {
        db.execute('PRAGMA user_version = 153');
        db.execute('''
          CREATE TABLE service_kinds (
            id TEXT NOT NULL PRIMARY KEY,
            diver_id TEXT,
            name TEXT NOT NULL,
            applicable_types TEXT NOT NULL DEFAULT '[]',
            default_interval_days INTEGER,
            default_interval_dives INTEGER,
            default_interval_hours REAL,
            auto_attach INTEGER NOT NULL DEFAULT 0,
            is_built_in INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            hlc TEXT
          )
        ''');
        db.execute(
          "INSERT INTO service_kinds (id, name, created_at, updated_at) "
          "VALUES ('disinfect', 'Disinfect', 1, 1)",
        );
      },
    );

    final db = AppDatabase(native);
    addTearDown(db.close);

    final cols = await db
        .customSelect("PRAGMA table_info('service_kinds')")
        .get();
    final byName = {for (final c in cols) c.read<String>('name'): c};
    expect(byName.containsKey('default_cost'), isTrue);
    expect(byName.containsKey('default_currency'), isTrue);
    expect(byName['default_cost']!.read<String>('type').toUpperCase(), 'REAL');
    expect(
      byName['default_currency']!.read<String>('type').toUpperCase(),
      'TEXT',
    );

    final row = await db
        .customSelect('SELECT name, default_cost FROM service_kinds')
        .getSingle();
    expect(row.read<String>('name'), 'Disinfect');
    expect(row.read<double?>('default_cost'), isNull);
  });

  test('migration list includes v154 and schema is at least 154', () {
    expect(AppDatabase.currentSchemaVersion, greaterThanOrEqualTo(154));
    expect(AppDatabase.migrationVersions, contains(154));
  });

  test('v154 is idempotent when a column already exists', () async {
    final native = NativeDatabase.memory(
      setup: (db) {
        db.execute('PRAGMA user_version = 153');
        db.execute('''
          CREATE TABLE service_schedules (
            id TEXT NOT NULL PRIMARY KEY,
            equipment_id TEXT NOT NULL,
            service_kind_id TEXT NOT NULL,
            interval_days INTEGER,
            interval_dives INTEGER,
            interval_hours REAL,
            anchor_date INTEGER,
            enabled INTEGER NOT NULL DEFAULT 1,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            hlc TEXT,
            default_cost REAL
          )
        ''');
      },
    );

    final db = AppDatabase(native);
    addTearDown(db.close);

    final cols = await db
        .customSelect("PRAGMA table_info('service_schedules')")
        .get();
    final names = cols.map((c) => c.read<String>('name')).toList();
    expect(names.where((n) => n == 'default_cost').length, 1);
    expect(names, contains('default_currency'));
  });

  test('the helper no-ops when the tables are absent', () async {
    final native = NativeDatabase.memory(
      setup: (db) => db.execute('PRAGMA user_version = 153'),
    );
    final db = AppDatabase(native);
    addTearDown(db.close);

    await expectLater(db.customSelect('SELECT 1').get(), completes);
  });
}
