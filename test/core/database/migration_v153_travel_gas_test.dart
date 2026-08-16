import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/core/database/database.dart';

void main() {
  test('v153 is in the migration ladder', () {
    expect(AppDatabase.currentSchemaVersion, greaterThanOrEqualTo(153));
    expect(AppDatabase.migrationVersions, contains(153));
  });

  test('a fresh database has dive_plan_tanks.is_travel_gas', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final cols = await db
        .customSelect("PRAGMA table_info('dive_plan_tanks')")
        .get();
    final names = cols.map((c) => c.read<String>('name')).toSet();
    expect(names, contains('is_travel_gas'));
  });

  test('the column is not null and defaults false', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final cols = await db
        .customSelect("PRAGMA table_info('dive_plan_tanks')")
        .get();
    final column = cols.firstWhere(
      (c) => c.read<String>('name') == 'is_travel_gas',
    );
    expect(column.read<int>('notnull'), 1);
  });

  test(
    'a database stranded before v153 gains the column via beforeOpen',
    () async {
      final nativeDb = NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('''
          CREATE TABLE dive_plan_tanks (
            id TEXT NOT NULL PRIMARY KEY,
            plan_id TEXT NOT NULL,
            created_at INTEGER,
            updated_at INTEGER
          )
        ''');
        },
      );
      final db = AppDatabase(nativeDb);
      addTearDown(db.close);

      final cols = await db
          .customSelect("PRAGMA table_info('dive_plan_tanks')")
          .get();
      final names = cols.map((c) => c.read<String>('name')).toSet();
      expect(names, contains('is_travel_gas'));
    },
  );

  test('the assert is a no-op when the table is absent', () async {
    final nativeDb = NativeDatabase.memory(
      setup: (rawDb) {
        rawDb.execute('CREATE TABLE unrelated (id TEXT)');
      },
    );
    final db = AppDatabase(nativeDb);
    addTearDown(db.close);

    await db.customSelect('SELECT 1').get();
  });
}
