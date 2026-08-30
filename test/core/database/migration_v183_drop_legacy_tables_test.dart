import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:submersion/core/database/database.dart';

import '../../helpers/legacy_profile_fixtures.dart';

/// The sync bookkeeping the v183 rung purges. Hand-written to match the
/// Drift declarations of `SyncRecords` and `DeletionLog` (the fixture in
/// `legacy_profile_fixtures.dart` covers only the profile tables).
void syncBookkeepingDdl(sqlite3.Database rawDb) {
  rawDb.execute('''
    CREATE TABLE IF NOT EXISTS sync_records (
      id TEXT NOT NULL PRIMARY KEY,
      entity_type TEXT NOT NULL,
      record_id TEXT NOT NULL,
      local_updated_at INTEGER NOT NULL,
      synced_at INTEGER,
      sync_status TEXT NOT NULL DEFAULT 'synced',
      conflict_data TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''');
  rawDb.execute('''
    CREATE TABLE IF NOT EXISTS deletion_log (
      id TEXT NOT NULL PRIMARY KEY,
      entity_type TEXT NOT NULL,
      record_id TEXT NOT NULL,
      deleted_at INTEGER NOT NULL,
      hlc TEXT
    )
  ''');
}

/// One pending sync record and one tombstone per legacy entity type, plus a
/// `dives` row of each that must survive.
void seedSyncBookkeeping(sqlite3.Database rawDb) {
  rawDb.execute(
    'INSERT INTO sync_records (id, entity_type, record_id, local_updated_at, '
    'created_at, updated_at) VALUES '
    "('s1', 'diveProfiles', 'p1', 1, 1, 1), "
    "('s2', 'tankPressureProfiles', 'q1', 1, 1, 1), "
    "('s3', 'dives', 'd1', 1, 1, 1)",
  );
  rawDb.execute(
    'INSERT INTO deletion_log (id, entity_type, record_id, deleted_at) VALUES '
    "('l1', 'diveProfiles', 'p9', 1), "
    "('l2', 'tankPressureProfiles', 'q9', 1), "
    "('l3', 'dives', 'd9', 1)",
  );
}

/// The two legacy indexes the v183 rung drops by name. `legacyDdlAt180`
/// creates the tables without them, so a database that never ran
/// `ensurePerformanceIndexes` would make the DROP INDEX assertions vacuous.
void legacyIndexes(sqlite3.Database rawDb) {
  rawDb.execute(
    'CREATE INDEX IF NOT EXISTS idx_dive_profiles_dive_id '
    'ON dive_profiles(dive_id)',
  );
  rawDb.execute(
    'CREATE INDEX IF NOT EXISTS idx_tank_pressure_dive_tank '
    'ON tank_pressure_profiles(dive_id, tank_id, timestamp)',
  );
}

List<Object?> columnOf(sqlite3.Database rawDb, String sql, String column) {
  return rawDb.select(sql).map((r) => r[column]).toList();
}

int scalar(sqlite3.Database rawDb, String sql) {
  return rawDb.select(sql).first.values.first! as int;
}

void main() {
  test(
    'the v183 rung drops the legacy tables and purges their bookkeeping',
    () async {
      final raw = sqlite3.sqlite3.openInMemory();
      addTearDown(raw.close);
      legacyDdlAt180(raw, userVersion: 182);
      legacyIndexes(raw);
      seedParents(raw);
      // Legacy rows a device stamped 182 may still be holding: either the
      // v182 rung packed them and left them behind, or a parallel branch
      // claimed 182 first and they were never packed at all. Both must reach
      // the series tables before the drop.
      seedProfiles(raw);
      seedPressures(raw);
      syncBookkeepingDdl(raw);
      seedSyncBookkeeping(raw);

      final db = AppDatabase(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      await db.customSelect('SELECT 1').get();

      expect(
        raw.select(
          "SELECT name FROM sqlite_master WHERE name IN ('dive_profiles', "
          "'tank_pressure_profiles')",
        ),
        isEmpty,
      );
      expect(
        raw.select(
          "SELECT name FROM sqlite_master WHERE type = 'index' AND name IN "
          "('idx_dive_profiles_dive_id', 'idx_tank_pressure_dive_tank')",
        ),
        isEmpty,
      );
      expect(
        columnOf(raw, 'SELECT entity_type FROM sync_records', 'entity_type'),
        ['dives'],
      );
      expect(
        columnOf(raw, 'SELECT entity_type FROM deletion_log', 'entity_type'),
        ['dives'],
      );
      expect(
        scalar(raw, 'SELECT COUNT(*) AS n FROM dive_profile_series'),
        greaterThan(0),
      );
      expect(
        scalar(raw, 'SELECT COUNT(*) AS n FROM tank_pressure_series'),
        greaterThan(0),
      );
      expect(scalar(raw, 'PRAGMA user_version'), 183);

      await db.close();
    },
  );

  test('re-running the ladder at 183 is a no-op', () async {
    final raw = sqlite3.sqlite3.openInMemory();
    addTearDown(raw.close);
    legacyDdlAt180(raw, userVersion: 182);
    legacyIndexes(raw);
    seedParents(raw);
    seedProfiles(raw);
    seedPressures(raw);
    syncBookkeepingDdl(raw);
    seedSyncBookkeeping(raw);

    // Two Drift executors over one SQLite handle: the first runs the ladder,
    // the second finds a database already at 183 and must not throw on the
    // tables and bookkeeping that are already gone.
    final first = AppDatabase(
      NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
    );
    await first.customSelect('SELECT 1').get();
    await first.close();

    final profileSeries = scalar(
      raw,
      'SELECT COUNT(*) AS n FROM dive_profile_series',
    );
    final tankSeries = scalar(
      raw,
      'SELECT COUNT(*) AS n FROM tank_pressure_series',
    );
    final syncRecords = scalar(raw, 'SELECT COUNT(*) AS n FROM sync_records');
    final tombstones = scalar(raw, 'SELECT COUNT(*) AS n FROM deletion_log');

    final second = AppDatabase(
      NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
    );
    addTearDown(second.close);
    await expectLater(second.customSelect('SELECT 1').get(), completes);

    expect(
      scalar(raw, 'SELECT COUNT(*) AS n FROM dive_profile_series'),
      profileSeries,
    );
    expect(
      scalar(raw, 'SELECT COUNT(*) AS n FROM tank_pressure_series'),
      tankSeries,
    );
    expect(scalar(raw, 'SELECT COUNT(*) AS n FROM sync_records'), syncRecords);
    expect(scalar(raw, 'SELECT COUNT(*) AS n FROM deletion_log'), tombstones);
    expect(
      raw.select(
        "SELECT name FROM sqlite_master WHERE name IN ('dive_profiles', "
        "'tank_pressure_profiles')",
      ),
      isEmpty,
    );
    expect(scalar(raw, 'PRAGMA user_version'), 183);
  });

  test(
    'a database that skipped the v182 rung still packs before the drop',
    () async {
      final raw = sqlite3.sqlite3.openInMemory();
      addTearDown(raw.close);
      legacyDdlAt180(raw, userVersion: 181);
      legacyIndexes(raw);
      seedParents(raw);
      seedProfiles(raw);
      seedPressures(raw);

      final db = AppDatabase(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      addTearDown(db.close);
      await db.customSelect('SELECT 1').get();

      expect(
        raw.select(
          "SELECT name FROM sqlite_master WHERE name IN ('dive_profiles', "
          "'tank_pressure_profiles')",
        ),
        isEmpty,
      );
      // seedProfiles writes 11 rows in four identity groups, one pair of them
      // an exact duplicate; seedPressures writes 4 rows in two groups, again
      // with one exact duplicate. The packed sample counts are the seeded rows
      // minus those duplicates.
      expect(scalar(raw, 'SELECT COUNT(*) AS n FROM dive_profile_series'), 4);
      expect(
        scalar(raw, 'SELECT SUM(sample_count) AS n FROM dive_profile_series'),
        10,
      );
      expect(scalar(raw, 'SELECT COUNT(*) AS n FROM tank_pressure_series'), 2);
      expect(
        scalar(raw, 'SELECT SUM(sample_count) AS n FROM tank_pressure_series'),
        3,
      );
      expect(scalar(raw, 'PRAGMA user_version'), 183);
    },
  );

  test('v183 is present in the migration ladder', () {
    expect(AppDatabase.currentSchemaVersion, 183);
    expect(AppDatabase.migrationVersions, contains(183));
    // The wire compatibility floor stays where v182 put it: v183 removes no
    // synced column or entity that v182 had not already replaced.
    expect(AppDatabase.minimumCompatibleSchemaVersion, 182);
  });
}
