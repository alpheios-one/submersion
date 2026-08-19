import 'package:sqlite3/sqlite3.dart' show Database;

import 'package:submersion/core/database/sqlcipher_setup.dart';

/// How long a connection waits for a lock another connection holds before it
/// gives up with SQLITE_BUSY ("database is locked", result code 5).
///
/// SQLite's default is ZERO: without this, the first statement to meet a lock
/// fails instantly rather than waiting for the microseconds-to-milliseconds
/// the holder actually needs. That is not hypothetical here -- the main
/// database is opened from two isolates (the UI isolate and the Workmanager
/// headless isolate), and `beforeOpen` re-asserts schema and re-seeds the
/// built-in reference data on EVERY open, so both isolates write the moment
/// they connect.
///
/// Five seconds is a deliberate middle: comfortably longer than the open-time
/// re-assert an overlapping isolate is doing, and short enough that a lock
/// that is genuinely stuck still surfaces as an error instead of presenting
/// as a hung launch.
const Duration kDatabaseBusyTimeout = Duration(seconds: 5);

/// Applies the settings every connection to the MAIN database needs, in the
/// order SQLite requires them, and returns the journal mode the connection
/// ended up in.
///
/// The order is not cosmetic:
///
/// 1. [keyHex] when present. SQLCipher's key pragma must be the first
///    statement executed on a connection, before anything (the busy timeout
///    included) touches a page.
/// 2. The busy timeout, BEFORE the journal mode. Converting a database to WAL
///    takes a brief exclusive lock, so on a file another isolate already has
///    open the conversion is exactly the kind of statement the timeout exists
///    to let wait rather than fail.
/// 3. WAL. See [_applyWalJournalMode].
///
/// Deliberately lives next to [cipherKeyPragma] rather than on
/// `DatabaseService`, so the drift worker isolate can call it without
/// importing `database_service.dart` -- that file imports this one.
String applyMainDatabaseSetup(Database db, {String? keyHex}) {
  applyConnectionBasics(db, keyHex: keyHex);
  return _applyWalJournalMode(db);
}

/// The part of [applyMainDatabaseSetup] that is safe on ANY database file:
/// the key and the busy timeout, both of which are per-connection settings
/// that leave no trace in the file.
///
/// The journal mode is deliberately not here. It is written into the database
/// header and outlives the connection, so a short-lived probe -- a schema
/// version read, an integrity check, a look at what a folder holds -- must not
/// impose it. Several of those probes run against BACKUP ARTIFACTS, which have
/// to stay single self-contained files: converting one to WAL would leave
/// `-wal`/`-shm` next to it and make the next read-only open (a file the
/// picker handed us out of a read-only directory) need an `-shm` it cannot
/// create.
void applyConnectionBasics(Database db, {String? keyHex}) {
  if (keyHex != null) {
    db.execute(cipherKeyPragma(keyHex));
  }
  db.execute('PRAGMA busy_timeout = ${kDatabaseBusyTimeout.inMilliseconds}');
}

/// Asks for WAL and reports what SQLite actually settled on.
///
/// Why WAL: in the default rollback-journal (`DELETE`) mode a reader blocks a
/// writer and a writer blocks everything. The main database is opened from two
/// isolates (the UI isolate and the Workmanager headless isolate) and
/// `beforeOpen` re-asserts schema and re-seeds reference data on EVERY open,
/// so both write the moment they connect. Under WAL readers and a writer no
/// longer exclude each other, which removes most of that contention instead of
/// waiting it out with [kDatabaseBusyTimeout].
///
/// Never fatal. WAL needs to place `-wal` and `-shm` next to the database and
/// needs real shared memory, which some filesystems cannot provide -- a
/// network mount, or an in-memory database. SQLite's own answer there is to
/// keep the existing mode and report it rather than to fail, and an
/// unavailable optimisation must not cost a diver their launch, so a hard
/// error is caught and answered the same way.
///
/// Anything that copies the database file must be WAL-aware once this is on:
/// committed data lives in `<db>-wal` until a checkpoint folds it back, so a
/// byte copy of `<db>` alone is missing the newest rows. See
/// `vacuumIntoSnapshot`, which is how backups avoid that.
String _applyWalJournalMode(Database db) {
  try {
    // Returns one row holding the resulting mode -- 'wal' on success, the
    // unchanged previous mode when SQLite declines.
    final result = db.select('PRAGMA journal_mode = WAL');
    if (result.isNotEmpty) {
      return result.first.values.first as String? ?? '';
    }
  } catch (_) {
    // Fall through to reporting whatever mode the connection is in.
  }
  try {
    return db.select('PRAGMA journal_mode').first.values.first as String? ?? '';
  } catch (_) {
    return '';
  }
}
