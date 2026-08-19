import 'dart:async';

import 'package:sqlite3/sqlite3.dart' show Database, SqliteException;

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

/// SQLite primary result code 5, SQLITE_BUSY: another connection holds the
/// lock. 6, SQLITE_LOCKED, is the same story inside one connection.
const int _sqliteBusy = 5;
const int _sqliteLocked = 6;

/// SQLite's exact `errmsg` texts for a lock, matched when the result code is
/// out of reach: drift's remote executor and the isolate boundary can both
/// re-wrap a failure into a plainer error type.
const List<String> _busyMessages = [
  'database is locked',
  'database table is locked',
  'database schema is locked',
];

/// True when [error] is SQLite refusing to proceed because something else
/// holds a lock.
///
/// Deliberately shared: the startup screen classifies on it to decide what to
/// tell the diver, and the open path retries on it. One definition means the
/// two can never disagree about what counts as a lock.
bool isDatabaseBusyError(Object error) {
  if (error is SqliteException &&
      (error.resultCode == _sqliteBusy || error.resultCode == _sqliteLocked)) {
    return true;
  }
  final message = error.toString().toLowerCase();
  return _busyMessages.any(message.contains);
}

/// How many times an open is attempted before a lock is allowed to fail it.
const int kDatabaseBusyOpenAttempts = 4;

/// Base delay between those attempts; the wait grows linearly with the
/// attempt number, so four attempts span roughly 1.5 seconds of backoff on
/// top of whatever [kDatabaseBusyTimeout] already absorbed.
const Duration kDatabaseBusyOpenBackoff = Duration(milliseconds: 250);

/// Runs [attempt], retrying while SQLite reports the database is locked.
///
/// [kDatabaseBusyTimeout] is not enough on its own, and the gap is not an
/// edge case. A busy timeout only helps when SQLite is willing to WAIT, and
/// it refuses to wait for one specific conflict: a connection that already
/// holds a SHARED (read) lock and needs to promote it to RESERVED while
/// another connection holds RESERVED. Waiting there could deadlock, so SQLite
/// returns SQLITE_BUSY immediately without ever consulting the busy handler.
///
/// That conflict is reachable on every open, because `beforeOpen` re-seeds the
/// built-in reference data with read-then-write statements -- `INSERT OR
/// IGNORE INTO service_kinds ... SELECT ...` takes the read lock for its
/// SELECT and then needs the write lock. Measured: it fails in 0ms, not after
/// the 5s timeout.
///
/// SQLite's own prescription for that case is for the caller to drop its read
/// lock and try again, which is exactly what closing and reopening does. So
/// [attempt] must be self-contained: it has to build its own connection and
/// dispose of it on failure, both because a drift executor caches its
/// migration error and rethrows it forever after, and because the retry only
/// helps if the previous attempt's read lock is gone.
Future<T> retryWhileDatabaseBusy<T>(
  Future<T> Function() attempt, {
  int attempts = kDatabaseBusyOpenAttempts,
  Duration backoff = kDatabaseBusyOpenBackoff,
  Future<void> Function(Duration)? delay,
}) async {
  final sleep = delay ?? (d) => Future<void>.delayed(d);
  for (var tries = 1; ; tries++) {
    try {
      return await attempt();
    } catch (error) {
      if (tries >= attempts || !isDatabaseBusyError(error)) rethrow;
      await sleep(backoff * tries);
    }
  }
}
