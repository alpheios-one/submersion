import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// The row-per-sample profile shape that preceded the packed series tables,
/// with the foreign-key parents those tables reference.
///
/// [userVersion] chooses which ladder rungs run on the next open: 180 lets
/// the v182 rung run, 182 stamps a database the ladder skips entirely.
///
/// is_primary/imported_at/created_at on dive_data_sources are not part of
/// what the packer reads, but the unconditional beforeOpen self-heal
/// `_backfillMissingDataSources` runs once dives, dive_profile_series, and
/// dive_data_sources all exist and inserts rows naming those columns. It
/// never touches dive_profiles.source_id.
void legacyDdlAt180(sqlite3.Database rawDb, {int userVersion = 180}) {
  rawDb.execute('PRAGMA user_version = $userVersion');
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

/// Two dives, two computers, two data sources, two tanks.
void seedParents(sqlite3.Database rawDb) {
  rawDb.execute("INSERT INTO dives (id) VALUES ('d1'), ('d2')");
  rawDb.execute("INSERT INTO dive_computers (id) VALUES ('c1'), ('c2')");
  rawDb.execute(
    'INSERT INTO dive_data_sources (id, dive_id, computer_id, imported_at, '
    "created_at) VALUES ('s1', 'd1', 'c1', 0, 0), ('s2', 'd1', 'c2', 0, 0)",
  );
  rawDb.execute(
    "INSERT INTO dive_tanks (id, dive_id) VALUES ('t1', 'd1'), ('t2', 'd1')",
  );
}

/// dive d1: computer c1 / source s1, primary, 3 samples with the second
/// duplicated exactly and a third row at the same timestamp that differs;
/// computer c2 / source s2, non-primary, 2 samples (a multi-source dive);
/// a manual edit (null computer, source s1, primary), 2 samples.
/// dive d2: legacy rows with null computer and null source, 2 samples.
void seedProfiles(sqlite3.Database rawDb) {
  void row(
    String id,
    String dive,
    String? computer,
    String? source,
    int primary,
    int ts,
    double depth, {
    double? temp,
    int? ndl,
    double? ceiling,
    int? decoType,
    String? hrs,
  }) {
    rawDb.execute(
      'INSERT INTO dive_profiles (id, dive_id, computer_id, source_id, '
      'is_primary, timestamp, depth, temperature, ndl, ceiling, deco_type, '
      'heart_rate_source) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        id,
        dive,
        computer,
        source,
        primary,
        ts,
        depth,
        temp,
        ndl,
        ceiling,
        decoType,
        hrs,
      ],
    );
  }

  row('p1', 'd1', 'c1', 's1', 1, 0, 0.0, temp: 20.0, ndl: 3000);
  row('p2', 'd1', 'c1', 's1', 1, 10, 12.5, temp: 19.5, ndl: 2900);
  row('p3', 'd1', 'c1', 's1', 1, 10, 12.5, temp: 19.5, ndl: 2900);
  row('p4', 'd1', 'c1', 's1', 1, 10, 12.7, temp: 19.5, ndl: 2900);
  row('p5', 'd1', 'c1', 's1', 1, 20, 18.0, ceiling: 3.0, decoType: 2);
  row('p6', 'd1', 'c2', 's2', 0, 0, 0.0);
  row('p7', 'd1', 'c2', 's2', 0, 10, 12.4);
  row('p8', 'd1', null, 's1', 1, 0, 0.0, hrs: 'appleWatch');
  row('p9', 'd1', null, 's1', 1, 10, 12.0, hrs: 'appleWatch');
  row('p10', 'd2', null, null, 1, 0, 0.0);
  row('p11', 'd2', null, null, 1, 30, 9.0);
}

/// Tank t1 on computer c1 with an exact duplicate reading, tank t2 with no
/// computer.
void seedPressures(sqlite3.Database rawDb) {
  void row(String id, String tank, String? computer, int ts, double bar) {
    rawDb.execute(
      'INSERT INTO tank_pressure_profiles (id, dive_id, tank_id, timestamp, '
      'pressure, computer_id) VALUES (?, ?, ?, ?, ?, ?)',
      [id, 'd1', tank, ts, bar, computer],
    );
  }

  row('q1', 't1', 'c1', 0, 200.0);
  row('q2', 't1', 'c1', 0, 200.0);
  row('q3', 't1', 'c1', 60, 190.0);
  row('q4', 't2', null, 0, 210.0);
}
