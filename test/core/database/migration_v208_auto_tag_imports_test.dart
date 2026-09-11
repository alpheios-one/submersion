import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/core/database/database.dart';

void main() {
  test('v208 is the current schema version and is in the ladder', () {
    expect(AppDatabase.currentSchemaVersion, greaterThanOrEqualTo(208));
    expect(AppDatabase.migrationVersions, contains(208));
  });

  test('a fresh database has diver_settings.auto_tag_imports, on', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final cols = await db
        .customSelect("PRAGMA table_info('diver_settings')")
        .get();
    final column = cols.firstWhere(
      (c) => c.read<String>('name') == 'auto_tag_imports',
    );
    expect(column.read<int>('notnull'), 1);
    expect(column.read<String?>('dflt_value'), contains('1'));
  });

  test(
    'a database stranded before v208 gains the column via beforeOpen',
    () async {
      final nativeDb = NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('''
          CREATE TABLE diver_settings (
            id TEXT NOT NULL PRIMARY KEY,
            created_at INTEGER,
            updated_at INTEGER
          )
        ''');
        },
      );
      final db = AppDatabase(nativeDb);
      addTearDown(db.close);

      final cols = await db
          .customSelect("PRAGMA table_info('diver_settings')")
          .get();
      final names = cols.map((c) => c.read<String>('name')).toSet();
      expect(names, contains('auto_tag_imports'));
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
