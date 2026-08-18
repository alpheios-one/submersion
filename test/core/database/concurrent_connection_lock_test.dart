import 'dart:io';
import 'dart:isolate';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:submersion/core/database/database.dart';
import 'package:submersion/core/database/database_connection_setup.dart';
import 'package:submersion/core/services/database_location_service.dart';
import 'package:submersion/core/services/database_service.dart';

/// Opens [path] in a second isolate, takes the write lock, and holds it.
///
/// A second ISOLATE is load-bearing: `busy_timeout` blocks the calling isolate
/// inside sqlite3, so a lock released by a timer on the main isolate could
/// never fire while the main isolate waits on it. This also mirrors
/// production, where the lock holder is the Workmanager headless isolate.
///
/// Message: [SendPort, path, holdMillis].
void _holdWriteLock(List<Object> message) {
  final port = message[0] as SendPort;
  final path = message[1] as String;
  final holdMillis = message[2] as int;

  final db = sqlite3.sqlite3.open(path);
  try {
    db.execute('PRAGMA busy_timeout = 10000');
    // IMMEDIATE takes the RESERVED lock straight away, so other connections
    // can still read but none of them can write -- exactly the state the
    // failing device was in.
    db.execute('BEGIN IMMEDIATE');
    db.execute('CREATE TABLE IF NOT EXISTS lock_probe (id INTEGER)');
    port.send('locked');
    sleep(Duration(milliseconds: holdMillis));
    db.execute('COMMIT');
  } finally {
    db.close();
  }
  port.send('released');
}

class _FakeLocation implements DatabaseLocationService {
  _FakeLocation(this.path);
  final String path;

  @override
  Future<String> getDatabasePath() async => path;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String dbPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('db-lock-test');
    dbPath = p.join(tempDir.path, 'submersion.db');
    DatabaseService.instance.resetForTesting();
  });

  tearDown(() async {
    try {
      await DatabaseService.instance.close(strict: true);
    } finally {
      DatabaseService.instance.resetForTesting();
      await tempDir.delete(recursive: true);
    }
  });

  /// Brings the file to the current schema and closes it: the state a
  /// returning user's database is in when the app launches.
  Future<void> seedDatabaseFile() async {
    final seeded = AppDatabase(NativeDatabase(File(dbPath)));
    await seeded.customSelect('SELECT 1').get();
    await seeded.close();
  }

  /// Spawns the holder and returns once it actually holds the lock.
  Future<void> holdWriteLockFor(int holdMillis) async {
    final events = ReceivePort();
    final isolate = await Isolate.spawn(_holdWriteLock, <Object>[
      events.sendPort,
      dbPath,
      holdMillis,
    ]);
    addTearDown(() {
      events.close();
      isolate.kill(priority: Isolate.immediate);
    });
    await events.asBroadcastStream().firstWhere((e) => e == 'locked');
  }

  test('openRaw applies the busy timeout', () async {
    await seedDatabaseFile();

    final db = DatabaseService.openRaw(dbPath);
    addTearDown(db.close);

    final rows = db.select('PRAGMA busy_timeout');
    expect(rows.single.values.first, kDatabaseBusyTimeout.inMilliseconds);
  });

  test('a normal open rides out a write lock held by another isolate', () async {
    await seedDatabaseFile();
    // Longer than any statement the open issues, well inside the busy timeout.
    await holdWriteLockFor(1500);

    // beforeOpen re-asserts schema and re-seeds the built-in reference data
    // (pre_dive_checklist_templates among it) on EVERY open, so this open
    // writes while the other isolate holds the lock.
    await DatabaseService.instance.initialize(
      locationService: _FakeLocation(dbPath),
    );

    expect(DatabaseService.instance.lastOpenMode, DatabaseOpenMode.background);
    final seeds = await DatabaseService.instance.database
        .customSelect(
          'SELECT COUNT(*) AS c FROM pre_dive_checklist_templates '
          'WHERE is_built_in = 1',
        )
        .getSingle();
    expect(seeds.read<int>('c'), greaterThan(0));
  });

  test(
    'the upgrade ladder rides out a write lock held by another isolate',
    () async {
      await seedDatabaseFile();

      // Roll the stored version back one step so the launch has a pending
      // upgrade, the situation the field report came from. The ladder's steps
      // are idempotent by contract, so replaying the last one is safe.
      final rollback = DatabaseService.openRaw(dbPath);
      rollback.execute(
        'PRAGMA user_version = ${AppDatabase.currentSchemaVersion - 1}',
      );
      rollback.close();

      await holdWriteLockFor(1500);

      await DatabaseService.instance.initialize(
        locationService: _FakeLocation(dbPath),
      );

      expect(
        DatabaseService.instance.lastOpenMode,
        DatabaseOpenMode.migrationThenBackground,
      );
      final version = await DatabaseService.instance.database
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.data.values.first, AppDatabase.currentSchemaVersion);
    },
  );
}
