import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/core/database/profile_series_pack.dart';
import 'package:submersion/core/services/sync/hlc.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_sample.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_series_codec.dart';
import 'package:submersion/features/dive_log/domain/codecs/tank_pressure_series_codec.dart';
import 'package:submersion/features/dive_log/domain/entities/profile_series.dart';

/// A database already at v182 (no ladder runs) with the legacy tables and
/// the FK parents the series tables reference. `beforeOpen` creates the
/// series tables through the backstop.
NativeDatabase legacyFixture({void Function(dynamic rawDb)? seed}) {
  return NativeDatabase.memory(
    setup: (rawDb) {
      rawDb.execute('PRAGMA user_version = 182');
      rawDb.execute('CREATE TABLE dives (id TEXT NOT NULL PRIMARY KEY)');
      rawDb.execute(
        'CREATE TABLE dive_computers (id TEXT NOT NULL PRIMARY KEY)',
      );
      // is_primary/imported_at/created_at are not part of what the packer
      // reads, but the unconditional beforeOpen self-heal
      // _backfillMissingDataSources runs once dives, dive_profiles, and
      // dive_data_sources all exist and inserts rows naming those columns.
      // It never touches dive_profiles.source_id, so the packer's
      // expectations below are unaffected.
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
      seed?.call(rawDb);
    },
  );
}

void seedParents(dynamic rawDb) {
  rawDb.execute("INSERT INTO dives (id) VALUES ('d1'), ('d2')");
  rawDb.execute("INSERT INTO dive_computers (id) VALUES ('c1'), ('c2')");
  rawDb.execute(
    "INSERT INTO dive_data_sources (id, dive_id, computer_id, imported_at, "
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
void seedProfiles(dynamic rawDb) {
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

void seedPressures(dynamic rawDb) {
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

Future<List<Map<String, Object?>>> rows(AppDatabase db, String sql) async {
  final result = await db.customSelect(sql).get();
  return result.map((r) => r.data).toList();
}

void main() {
  const codec = ProfileSeriesCodec();
  const tankCodec = TankPressureSeriesCodec();

  test('packs each identity group into one series with derived ids', () async {
    final db = AppDatabase(
      legacyFixture(
        seed: (raw) {
          seedParents(raw);
          seedProfiles(raw);
          seedPressures(raw);
        },
      ),
    );
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();

    final report = await packLegacyProfileRows(db, nowMs: 1700000000000);
    expect(report.profileSeries, 4);
    expect(report.tankSeries, 2);
    expect(report.droppedSamples, 2, reason: 'p3 and q2 are exact duplicates');

    final series = await rows(
      db,
      'SELECT * FROM dive_profile_series ORDER BY dive_id, computer_id, '
      'source_id, is_primary',
    );
    expect(series, hasLength(4));

    final c1 = series.singleWhere(
      (r) => r['computer_id'] == 'c1' && r['dive_id'] == 'd1',
    );
    expect(
      c1['id'],
      profileSeriesMigratedId(
        diveId: 'd1',
        computerId: 'c1',
        sourceId: 's1',
        isPrimary: true,
      ),
    );
    expect(c1['is_primary'], 1);
    expect(c1['sample_count'], 4);
    expect(c1['start_timestamp'], 0);
    expect(c1['end_timestamp'], 20);
    expect(c1['max_depth'], 18.0);
    expect(c1['first_depth'], 0.0);
    expect(c1['last_depth'], 18.0);
    expect(c1['has_deco_type'], 1);
    expect(c1['has_deco_stop'], 1);
    expect(c1['has_positive_ceiling'], 1);
    expect(c1['codec_version'], 1);
    expect(c1['created_at'], 1700000000000);
    expect(c1['updated_at'], 1700000000000);
    final decoded = codec.decode(c1['samples'] as dynamic);
    expect(decoded, [
      const ProfileSample(
        timestamp: 0,
        depth: 0.0,
        temperature: 20.0,
        ndl: 3000,
      ),
      const ProfileSample(
        timestamp: 10,
        depth: 12.5,
        temperature: 19.5,
        ndl: 2900,
      ),
      const ProfileSample(
        timestamp: 10,
        depth: 12.7,
        temperature: 19.5,
        ndl: 2900,
      ),
      const ProfileSample(
        timestamp: 20,
        depth: 18.0,
        ceiling: 3.0,
        decoType: 2,
      ),
    ]);

    final edit = series.singleWhere(
      (r) => r['computer_id'] == null && r['dive_id'] == 'd1',
    );
    expect(edit['source_id'], 's1');
    expect(edit['is_primary'], 1);
    expect(
      codec.decode(edit['samples'] as dynamic).map((s) => s.heartRateSource),
      ['appleWatch', 'appleWatch'],
    );

    final legacy = series.singleWhere((r) => r['dive_id'] == 'd2');
    expect(legacy['computer_id'], isNull);
    expect(legacy['source_id'], isNull);
    expect(
      legacy['id'],
      profileSeriesMigratedId(
        diveId: 'd2',
        computerId: null,
        sourceId: null,
        isPrimary: true,
      ),
    );

    final tanks = await rows(
      db,
      'SELECT * FROM tank_pressure_series ORDER BY tank_id',
    );
    expect(tanks, hasLength(2));
    expect(
      tanks[0]['id'],
      tankPressureSeriesMigratedId(
        diveId: 'd1',
        tankId: 't1',
        computerId: 'c1',
      ),
    );
    expect(tanks[0]['sample_count'], 2);
    expect(tankCodec.decode(tanks[0]['samples'] as dynamic), [
      const TankPressureSample(timestamp: 0, pressure: 200.0),
      const TankPressureSample(timestamp: 60, pressure: 190.0),
    ]);
    expect(tanks[1]['computer_id'], isNull);
  });

  test('re-running the packer inserts nothing new', () async {
    final db = AppDatabase(
      legacyFixture(
        seed: (raw) {
          seedParents(raw);
          seedProfiles(raw);
          seedPressures(raw);
        },
      ),
    );
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();

    await packLegacyProfileRows(db, nowMs: 1);
    final again = await packLegacyProfileRows(db, nowMs: 2);
    expect(again.profileSeries, 0);
    expect(again.tankSeries, 0);
    final count = await db
        .customSelect('SELECT COUNT(*) AS n FROM dive_profile_series')
        .getSingle();
    expect(count.read<int>('n'), 4);
  });

  test(
    'two independently packed copies produce identical series ids',
    () async {
      Future<Set<String>> idsOf() async {
        final db = AppDatabase(
          legacyFixture(
            seed: (raw) {
              seedParents(raw);
              seedProfiles(raw);
              seedPressures(raw);
            },
          ),
        );
        addTearDown(db.close);
        await db.customSelect('SELECT 1').get();
        await packLegacyProfileRows(db, nowMs: 5);
        final a = await rows(db, 'SELECT id FROM dive_profile_series');
        final b = await rows(db, 'SELECT id FROM tank_pressure_series');
        return {
          for (final r in [...a, ...b]) r['id'] as String,
        };
      }

      expect(await idsOf(), await idsOf());
    },
  );

  test(
    'stamps the migration hlc from sync_metadata when a device id exists',
    () async {
      final db = AppDatabase(
        legacyFixture(
          seed: (raw) {
            seedParents(raw);
            seedProfiles(raw);
            // A fixture stamped at 182 never runs onCreate, so the table a
            // synced device would have is created here with its global row.
            raw.execute(
              'CREATE TABLE sync_metadata (id TEXT NOT NULL PRIMARY KEY, '
              'device_id TEXT NOT NULL, created_at INTEGER NOT NULL, '
              'updated_at INTEGER NOT NULL)',
            );
            raw.execute(
              "INSERT INTO sync_metadata (id, device_id, created_at, updated_at) "
              "VALUES ('global', 'dev-1', 0, 0)",
            );
          },
        ),
      );
      addTearDown(db.close);
      await db.customSelect('SELECT 1').get();

      await packLegacyProfileRows(db, nowMs: 1700000000000);
      final row = await db
          .customSelect('SELECT hlc FROM dive_profile_series LIMIT 1')
          .getSingle();
      expect(
        row.read<String>('hlc'),
        const Hlc(1700000000000, 0, 'dev-1').toString(),
      );
    },
  );

  test('leaves hlc null when the device has never synced', () async {
    final db = AppDatabase(
      legacyFixture(
        seed: (raw) {
          seedParents(raw);
          seedProfiles(raw);
        },
      ),
    );
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();

    await packLegacyProfileRows(db, nowMs: 1);
    final row = await db
        .customSelect('SELECT hlc FROM dive_profile_series LIMIT 1')
        .getSingle();
    expect(row.readNullable<String>('hlc'), isNull);
  });

  test('no-ops when the legacy tables are absent', () async {
    final db = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) => raw.execute('PRAGMA user_version = 182'),
      ),
    );
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();

    final report = await packLegacyProfileRows(db, nowMs: 1);
    expect(report.profileSeries, 0);
    expect(report.tankSeries, 0);
    expect(report.droppedSamples, 0);
  });

  test('tolerates legacy tables that lack optional sample columns', () async {
    // A minimal fixture like the older migration tests: the identity columns
    // and the two required sample columns only. The identity columns are
    // always present by the time the v182 rung runs (earlier rungs add
    // source_id first, and rungs run in order), so the packer may name them
    // in ORDER BY; every optional sample column is absent here and must
    // decode as null.
    final db = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          raw.execute('PRAGMA user_version = 182');
          raw.execute('CREATE TABLE dives (id TEXT NOT NULL PRIMARY KEY)');
          raw.execute("INSERT INTO dives (id) VALUES ('d1')");
          // dive_profile_series.computer_id/source_id carry FK references to
          // these two tables. Under PRAGMA foreign_keys = ON (set in
          // beforeOpen), SQLite resolves an INSERT's foreign keys when the
          // statement is prepared, not when it runs, so both parent tables
          // must exist even though every row below leaves computer_id and
          // source_id null. Every real database has carried both tables since
          // long before v182. dive_data_sources needs the columns the
          // unconditional beforeOpen self-heal _backfillMissingDataSources
          // names once dives, dive_profiles, and dive_data_sources all exist
          // (see legacyFixture above); it never touches dive_profiles.source_id.
          raw.execute(
            'CREATE TABLE dive_computers (id TEXT NOT NULL PRIMARY KEY)',
          );
          raw.execute('''
            CREATE TABLE dive_data_sources (
              id TEXT NOT NULL PRIMARY KEY,
              dive_id TEXT NOT NULL,
              computer_id TEXT,
              is_primary INTEGER NOT NULL DEFAULT 0,
              imported_at INTEGER NOT NULL,
              created_at INTEGER NOT NULL
            )
          ''');
          raw.execute(
            'CREATE TABLE dive_profiles (id TEXT NOT NULL PRIMARY KEY, '
            'dive_id TEXT NOT NULL, computer_id TEXT, source_id TEXT, '
            'is_primary INTEGER NOT NULL DEFAULT 1, '
            'timestamp INTEGER NOT NULL, depth REAL NOT NULL)',
          );
          raw.execute(
            "INSERT INTO dive_profiles (id, dive_id, timestamp, depth) "
            "VALUES ('p1', 'd1', 0, 0), ('p2', 'd1', 5, 4)",
          );
        },
      ),
    );
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();

    final report = await packLegacyProfileRows(db, nowMs: 1);
    expect(report.profileSeries, 1);
    final row = await db
        .customSelect('SELECT samples FROM dive_profile_series')
        .getSingle();
    expect(codec.decode(row.read('samples')), [
      const ProfileSample(timestamp: 0, depth: 0.0),
      const ProfileSample(timestamp: 5, depth: 4.0),
    ]);
  });
}
