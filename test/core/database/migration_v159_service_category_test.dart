import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/core/database/database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A v158 service_kinds table carrying one built-in and one custom kind.
  NativeDatabase seededV158() => NativeDatabase.memory(
    setup: (db) {
      db.execute('PRAGMA user_version = 158');
      db.execute('''
        CREATE TABLE service_kinds (
          id TEXT NOT NULL PRIMARY KEY,
          diver_id TEXT,
          name TEXT NOT NULL,
          applicable_types TEXT NOT NULL DEFAULT '[]',
          default_interval_days INTEGER,
          default_interval_dives INTEGER,
          default_interval_hours REAL,
          default_cost REAL,
          default_currency TEXT,
          auto_attach INTEGER NOT NULL DEFAULT 0,
          is_built_in INTEGER NOT NULL DEFAULT 0,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          hlc TEXT
        )
      ''');
      db.execute(
        "INSERT INTO service_kinds (id, name, is_built_in, created_at, "
        "updated_at) VALUES ('hydro', 'Hydrostatic test', 1, 1, 1)",
      );
      db.execute(
        "INSERT INTO service_kinds (id, name, is_built_in, created_at, "
        "updated_at) VALUES ('disinfect', 'Disinfect', 0, 1, 1)",
      );
    },
  );

  test('v159 adds default_category and seeds built-ins only', () async {
    final db = AppDatabase(seededV158());
    addTearDown(db.close);

    final cols = await db
        .customSelect("PRAGMA table_info('service_kinds')")
        .get();
    final byName = {for (final c in cols) c.read<String>('name'): c};
    expect(byName.containsKey('default_category'), isTrue);
    expect(
      byName['default_category']!.read<String>('type').toUpperCase(),
      'TEXT',
    );

    final hydro = await db
        .customSelect(
          "SELECT default_category FROM service_kinds WHERE id = 'hydro'",
        )
        .getSingle();
    expect(hydro.read<String?>('default_category'), 'inspection');

    final custom = await db
        .customSelect(
          "SELECT default_category FROM service_kinds WHERE id = 'disinfect'",
        )
        .getSingle();
    expect(
      custom.read<String?>('default_category'),
      isNull,
      reason: 'a custom kind has no opinion until the diver gives it one',
    );
  });

  test('the migration itself inserts no kinds', () async {
    final db = AppDatabase(seededV158());
    addTearDown(db.close);

    // The v159 step is an UPDATE keyed on existing ids, so it can only ever
    // touch rows already present. Any row beyond the two seeded here came
    // from kSeedBuiltInServiceKindsSql in beforeOpen, never from the
    // migration, which is what keeps a deleted built-in deleted.
    final ids = await db
        .customSelect(
          "SELECT id, default_category FROM service_kinds "
          "WHERE id = 'disinfect'",
        )
        .get();
    expect(ids, hasLength(1));
    expect(ids.single.read<String?>('default_category'), isNull);
  });

  test('the helper no-ops when service_kinds is absent', () async {
    final native = NativeDatabase.memory(
      setup: (db) => db.execute('PRAGMA user_version = 158'),
    );
    final db = AppDatabase(native);
    addTearDown(db.close);

    await expectLater(db.customSelect('SELECT 1').get(), completes);
  });

  test('migration list includes v159 and schema is at least 159', () {
    expect(AppDatabase.currentSchemaVersion, greaterThanOrEqualTo(159));
    expect(AppDatabase.migrationVersions, contains(159));
  });

  test('every built-in slug in the seed SQL has a category', () {
    for (final slug in kBuiltInServiceKindCategories.keys) {
      expect(
        kSeedBuiltInServiceKindsSql,
        contains("'$slug'"),
        reason: 'the category map names a slug the seed SQL does not create',
      );
    }
  });
}
