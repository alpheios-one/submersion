import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:submersion/core/database/database.dart';

/// Minimal pre-v181 shape stamped at v180 so only the 181 rung runs. The FK
/// parents exist because the series tables reference them and foreign keys
/// are on once the database opens. Shared by [dbAt180] and the two-open
/// tests, which need the same DDL on a raw handle.
///
/// is_primary/imported_at/created_at on dive_data_sources are not part of
/// the series schema, but the unconditional beforeOpen self-heal
/// _backfillMissingDataSources (test/core/database/
/// backfill_missing_data_sources_test.dart) runs on every open once all of
/// dives, dive_profiles, and dive_data_sources exist, and needs them.
void legacyDdlAt180(dynamic rawDb) {
  rawDb.execute('PRAGMA user_version = 180');
  rawDb.execute('CREATE TABLE dives (id TEXT NOT NULL PRIMARY KEY)');
  rawDb.execute('CREATE TABLE dive_computers (id TEXT NOT NULL PRIMARY KEY)');
  rawDb.execute('''
    CREATE TABLE dive_data_sources (
      id TEXT NOT NULL PRIMARY KEY,
      dive_id TEXT NOT NULL,
      computer_id TEXT,
      is_primary INTEGER NOT NULL DEFAULT 0,
      imported_at INTEGER NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''');
  rawDb.execute(
    'CREATE TABLE dive_tanks (id TEXT NOT NULL PRIMARY KEY, '
    'dive_id TEXT NOT NULL)',
  );
  rawDb.execute('''
    CREATE TABLE dive_profiles (
      id TEXT NOT NULL PRIMARY KEY,
      dive_id TEXT NOT NULL,
      computer_id TEXT,
      source_id TEXT,
      is_primary INTEGER NOT NULL DEFAULT 1,
      timestamp INTEGER NOT NULL,
      depth REAL NOT NULL,
      temperature REAL,
      ndl INTEGER,
      ceiling REAL,
      deco_type INTEGER,
      heart_rate_source TEXT
    )
  ''');
  rawDb.execute('''
    CREATE TABLE tank_pressure_profiles (
      id TEXT NOT NULL PRIMARY KEY,
      dive_id TEXT NOT NULL,
      tank_id TEXT NOT NULL,
      timestamp INTEGER NOT NULL,
      pressure REAL NOT NULL,
      computer_id TEXT
    )
  ''');
}

NativeDatabase dbAt180({void Function(dynamic rawDb)? seed}) {
  return NativeDatabase.memory(
    setup: (rawDb) {
      legacyDdlAt180(rawDb);
      seed?.call(rawDb);
    },
  );
}

Future<Set<String>> tableNames(AppDatabase db) async {
  final rows = await db
      .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
      .get();
  return rows.map((r) => r.read<String>('name')).toSet();
}

Future<Set<String>> indexNames(AppDatabase db) async {
  final rows = await db
      .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
      .get();
  return rows.map((r) => r.read<String>('name')).toSet();
}

Future<Set<String>> columnsOf(AppDatabase db, String table) async {
  final cols = await db.customSelect("PRAGMA table_info('$table')").get();
  return cols.map((c) => c.read<String>('name')).toSet();
}

const profileSeriesColumns = {
  'id',
  'dive_id',
  'computer_id',
  'source_id',
  'is_primary',
  'sample_count',
  'start_timestamp',
  'end_timestamp',
  'max_depth',
  'first_depth',
  'last_depth',
  'has_deco_type',
  'has_deco_stop',
  'has_positive_ceiling',
  'codec_version',
  'samples',
  'created_at',
  'updated_at',
  'hlc',
};

const tankSeriesColumns = {
  'id',
  'dive_id',
  'tank_id',
  'computer_id',
  'sample_count',
  'start_timestamp',
  'end_timestamp',
  'codec_version',
  'samples',
  'created_at',
  'updated_at',
  'hlc',
};

void main() {
  group('schema', () {
    test(
      'v181 creates both series tables and their indexes on upgrade',
      () async {
        final db = AppDatabase(dbAt180());
        addTearDown(db.close);

        final tables = await tableNames(db);
        expect(
          tables,
          containsAll(['dive_profile_series', 'tank_pressure_series']),
        );
        expect(
          await columnsOf(db, 'dive_profile_series'),
          profileSeriesColumns,
        );
        expect(await columnsOf(db, 'tank_pressure_series'), tankSeriesColumns);
        final indexes = await indexNames(db);
        expect(
          indexes,
          containsAll([
            'idx_dive_profile_series_dive_primary',
            'idx_tank_pressure_series_dive_tank',
          ]),
        );
        // The legacy tables survive this plan untouched.
        expect(
          tables,
          containsAll(['dive_profiles', 'tank_pressure_profiles']),
        );
      },
    );

    test('a fresh database has the tables with the same columns', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.customSelect('SELECT 1').get();

      expect(await columnsOf(db, 'dive_profile_series'), profileSeriesColumns);
      expect(await columnsOf(db, 'tank_pressure_series'), tankSeriesColumns);
      // The Drift declaration and the raw DDL must agree, or a fresh install
      // and an upgraded one would diverge.
      final driftProfile = db.diveProfileSeries.$columns
          .map((c) => c.$name)
          .toSet();
      final driftTank = db.tankPressureSeries.$columns
          .map((c) => c.$name)
          .toSet();
      expect(driftProfile, profileSeriesColumns);
      expect(driftTank, tankSeriesColumns);
    });

    test(
      'the backstop is idempotent across a second open of one database',
      () async {
        // Two Drift executors over one SQLite handle: the first open runs the
        // ladder, the second runs only beforeOpen, so the backstop's IF NOT
        // EXISTS DDL genuinely executes a second time. A second query on the
        // same executor would never re-enter beforeOpen.
        final raw = sqlite3.sqlite3.openInMemory();
        addTearDown(raw.close);
        legacyDdlAt180(raw);

        final first = AppDatabase(
          NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
        );
        await first.customSelect('SELECT 1').get();
        await first.close();

        final second = AppDatabase(
          NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
        );
        addTearDown(second.close);
        await expectLater(second.customSelect('SELECT 1').get(), completes);
        expect(
          await tableNames(second),
          containsAll(['dive_profile_series', 'tank_pressure_series']),
        );
        final version = await second
            .customSelect('PRAGMA user_version')
            .getSingle();
        expect(version.data.values.first, 181);
      },
    );

    test('v181 is present in the migration ladder', () {
      expect(AppDatabase.currentSchemaVersion, 181);
      expect(AppDatabase.migrationVersions, contains(181));
      expect(AppDatabase.minimumCompatibleSchemaVersion, 170);
    });
  });

  group('packing on upgrade', () {
    void seed(dynamic rawDb) {
      rawDb.execute("INSERT INTO dives (id) VALUES ('d1')");
      rawDb.execute("INSERT INTO dive_computers (id) VALUES ('c1')");
      rawDb.execute(
        "INSERT INTO dive_data_sources (id, dive_id, computer_id, "
        "imported_at, created_at) VALUES ('s1', 'd1', 'c1', 0, 0)",
      );
      rawDb.execute("INSERT INTO dive_tanks (id, dive_id) VALUES ('t1', 'd1')");
      rawDb.execute(
        "INSERT INTO dive_profiles (id, dive_id, computer_id, source_id, "
        "is_primary, timestamp, depth) VALUES "
        "('p1', 'd1', 'c1', 's1', 1, 0, 0.0), "
        "('p2', 'd1', 'c1', 's1', 1, 10, 15.0), "
        "('p3', 'd1', 'c1', 's1', 1, 10, 15.0)",
      );
      rawDb.execute(
        "INSERT INTO tank_pressure_profiles (id, dive_id, tank_id, timestamp, "
        "pressure, computer_id) VALUES ('q1', 'd1', 't1', 0, 200.0, 'c1')",
      );
    }

    test('upgrading from 180 packs the legacy rows', () async {
      final db = AppDatabase(dbAt180(seed: seed));
      addTearDown(db.close);
      await db.customSelect('SELECT 1').get();

      final series = await db
          .customSelect('SELECT * FROM dive_profile_series')
          .get();
      expect(series, hasLength(1));
      expect(series.single.read<int>('sample_count'), 2);
      expect(series.single.read<double>('max_depth'), 15.0);
      final tanks = await db
          .customSelect('SELECT * FROM tank_pressure_series')
          .get();
      expect(tanks, hasLength(1));
      expect(tanks.single.read<String>('tank_id'), 't1');
      // Legacy rows are untouched in this plan.
      final legacy = await db
          .customSelect('SELECT COUNT(*) AS n FROM dive_profiles')
          .getSingle();
      expect(legacy.read<int>('n'), 3);
    });

    test(
      'two devices upgrading the same rows converge on the same ids',
      () async {
        Future<List<String>> idsAfterUpgrade() async {
          final db = AppDatabase(dbAt180(seed: seed));
          addTearDown(db.close);
          await db.customSelect('SELECT 1').get();
          final a = await db
              .customSelect('SELECT id FROM dive_profile_series ORDER BY id')
              .get();
          final b = await db
              .customSelect('SELECT id FROM tank_pressure_series ORDER BY id')
              .get();
          return [
            for (final r in [...a, ...b]) r.read<String>('id'),
          ];
        }

        expect(await idsAfterUpgrade(), await idsAfterUpgrade());
      },
    );

    test('a database already at 181 is not packed again on open', () async {
      // Two executors over one handle (see the schema group): the first
      // open runs the ladder and packs; a legacy row written afterwards must
      // survive the second open unpacked, because the backstop is schema
      // only.
      final raw = sqlite3.sqlite3.openInMemory();
      addTearDown(raw.close);
      legacyDdlAt180(raw);
      seed(raw);

      final first = AppDatabase(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      await first.customSelect('SELECT 1').get();
      await first.close();

      raw.execute(
        "INSERT INTO dive_profiles (id, dive_id, computer_id, source_id, "
        "is_primary, timestamp, depth) VALUES ('p9', 'd1', NULL, NULL, 1, 0, 1.0)",
      );

      final second = AppDatabase(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      addTearDown(second.close);
      await second.customSelect('SELECT 1').get();
      final series = await second
          .customSelect('SELECT COUNT(*) AS n FROM dive_profile_series')
          .getSingle();
      expect(series.read<int>('n'), 1);
    });
  });
}
