/// Thrown by `DatabaseService.restore` when the backup it was asked to swap
/// in does not exist at [backupPath].
///
/// The live database is left exactly as it was: the swap never starts, so no
/// "database unavailable" window opens and no data changes. That is the right
/// thing to do with the data, but it must not pass for a completed restore.
/// A user recovering from data loss cannot tell a restore that did nothing
/// apart from a restore of an empty library, and the two have very different
/// root causes (issue #1344). Callers surface this as "nothing was restored",
/// never as "Restore Complete".
class RestoreSourceMissingException implements Exception {
  /// The path the restore was pointed at; the file was absent by the time
  /// the swap ran (a download that produced no bytes, a temp directory reaped
  /// between materialization and use, a swallowed upstream error).
  final String backupPath;

  const RestoreSourceMissingException(this.backupPath);

  @override
  String toString() =>
      'RestoreSourceMissingException: backup file not found: $backupPath';
}
