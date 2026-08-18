/// Thrown when the database file was created by a newer version of
/// Submersion than the currently running app.
///
/// This prevents an older app from silently corrupting a newer schema
/// by running stale migrations or downgrading the version stamp.
///
/// Both fields are Drift SCHEMA versions (the `user_version` ladder), not
/// app release versions; the names say so because the older
/// `databaseVersion`/`appVersion` pair read as a marketing version and
/// invited that misreading.
class DatabaseVersionMismatchException implements Exception {
  final int storedSchemaVersion;
  final int supportedSchemaVersion;

  const DatabaseVersionMismatchException({
    required this.storedSchemaVersion,
    required this.supportedSchemaVersion,
  });

  @override
  String toString() =>
      'DatabaseVersionMismatchException: database is schema '
      'v$storedSchemaVersion but this app only supports up to '
      'v$supportedSchemaVersion. Please update Submersion to the latest '
      'version.';
}
