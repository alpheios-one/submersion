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
/// order SQLite requires them.
///
/// [keyHex] first when present: SQLCipher's key pragma must be the first
/// statement executed on a connection, before anything (the busy timeout
/// included) touches a page.
///
/// Deliberately lives next to [cipherKeyPragma] rather than on
/// `DatabaseService`, so the drift worker isolate can call it without
/// importing `database_service.dart` -- that file imports this one.
void applyMainDatabaseSetup(Database db, {String? keyHex}) {
  if (keyHex != null) {
    db.execute(cipherKeyPragma(keyHex));
  }
  db.execute('PRAGMA busy_timeout = ${kDatabaseBusyTimeout.inMilliseconds}');
}
