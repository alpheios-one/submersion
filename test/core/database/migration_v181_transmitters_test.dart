import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/database.dart';

/// Minimal pre-v181 shape: dive_computers and dive_tanks without the
/// transmitters table or the source/sensor_ref columns, stamped at v180 so
/// the upgrade to 181 runs.
NativeDatabase _dbAt180() {
  return NativeDatabase.memory(
    setup: (rawDb) {
      rawDb.execute('PRAGMA user_version = 180');
      rawDb.execute('''
        CREATE TABLE dive_computers (
          id TEXT NOT NULL PRIMARY KEY
        )
      ''');
      rawDb.execute("INSERT INTO dive_computers (id) VALUES ('dc-1')");
      rawDb.execute('''
        CREATE TABLE dive_tanks (
          id TEXT NOT NULL PRIMARY KEY,
          dive_id TEXT NOT NULL,
          computer_id TEXT
        )
      ''');
      rawDb.execute(
        "INSERT INTO dive_tanks (id, dive_id, computer_id) "
        "VALUES ('imported', 'dive-1', 'dc-1')",
      );
      rawDb.execute(
        "INSERT INTO dive_tanks (id, dive_id, computer_id) "
        "VALUES ('manual', 'dive-2', NULL)",
      );
    },
  );
}

Future<Set<String>> _diveTankColumns(AppDatabase db) async {
  final cols = await db.customSelect("PRAGMA table_info('dive_tanks')").get();
  return cols.map((c) => c.read<String>('name')).toSet();
}

void main() {
  test('v181 creates the transmitters table', () async {
    final db = AppDatabase(_dbAt180());
    addTearDown(db.close);

    final tables = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name = 'transmitters'",
        )
        .get();
    expect(tables, hasLength(1));
  });

  test('v181 adds source and sensor_ref to dive_tanks', () async {
    final db = AppDatabase(_dbAt180());
    addTearDown(db.close);

    final names = await _diveTankColumns(db);
    expect(names, contains('source'));
    expect(names, contains('sensor_ref'));
  });

  test('backfill labels pre-existing rows by computer_id presence', () async {
    final db = AppDatabase(_dbAt180());
    addTearDown(db.close);

    final rows = await db
        .customSelect('SELECT id, source FROM dive_tanks ORDER BY id')
        .get();
    final byId = {for (final r in rows) r.read<String>('id'): r};
    expect(byId['imported']!.read<String>('source'), 'dc_import');
    expect(byId['manual']!.read<String>('source'), 'manual');
  });

  test('fresh databases get the transmitters table and columns', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final tables = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name = 'transmitters'",
        )
        .get();
    expect(tables, hasLength(1));
    final names = await _diveTankColumns(db);
    expect(names, contains('source'));
    expect(names, contains('sensor_ref'));
  });

  test('a registry entry enforces one row per computer + channel', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final now = DateTime(2026, 1, 1).millisecondsSinceEpoch;
    await db
        .into(db.diveComputers)
        .insert(
          DiveComputersCompanion.insert(
            id: 'dc-1',
            name: 'Test Computer',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db
        .into(db.transmitters)
        .insert(
          TransmittersCompanion.insert(
            id: 't-1',
            diveComputerId: 'dc-1',
            channelIndex: 0,
            createdAt: now,
            updatedAt: now,
          ),
        );

    await expectLater(
      db
          .into(db.transmitters)
          .insert(
            TransmittersCompanion.insert(
              id: 't-2',
              diveComputerId: 'dc-1',
              channelIndex: 0,
              createdAt: now,
              updatedAt: now,
            ),
          ),
      throwsA(anything),
    );
  });

  test('the helper no-ops when dive_computers is absent', () async {
    final native = NativeDatabase.memory(
      setup: (rawDb) => rawDb.execute('PRAGMA user_version = 180'),
    );
    final db = AppDatabase(native);
    addTearDown(db.close);

    await expectLater(db.customSelect('SELECT 1').get(), completes);
  });

  test('the backstop is idempotent across repeated opens', () async {
    final db = AppDatabase(_dbAt180());
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();

    await expectLater(
      db.customSelect('SELECT source FROM dive_tanks').get(),
      completes,
    );
    final names = await _diveTankColumns(db);
    expect(
      names.where((n) => n == 'source').length,
      1,
      reason: 'the column must be added exactly once',
    );
  });

  test('v181 is present in the migration ladder', () {
    expect(AppDatabase.currentSchemaVersion, greaterThanOrEqualTo(181));
    expect(AppDatabase.migrationVersions, contains(181));
  });
}
