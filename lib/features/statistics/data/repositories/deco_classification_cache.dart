import 'package:drift/drift.dart';

import 'package:submersion/core/database/local_cache_database.dart';
import 'package:submersion/core/services/local_cache_database_service.dart';

/// Read and write access to the memoized computed deco classifications (#623).
///
/// Entries are only valid for the `inputsHash` they were written under, so a
/// changed profile, a changed gradient factor, or a bumped analysis engine
/// invalidates them without needing an explicit purge.
class DecoClassificationCacheRepository {
  DecoClassificationCacheRepository({LocalCacheDatabase? database})
    : _database = database;

  final LocalCacheDatabase? _database;

  LocalCacheDatabase get _db =>
      _database ?? LocalCacheDatabaseService.instance.database;

  /// The cached classifications for [diveIds] that were computed under
  /// [inputsHash]. Dives that are absent or stale are simply missing from the
  /// result, which is what marks them as needing recomputation.
  Future<Map<String, bool>> getValid(
    Set<String> diveIds,
    String inputsHash,
  ) async {
    if (diveIds.isEmpty) return const {};
    final rows =
        await (_db.select(_db.decoClassificationCache)..where(
              (t) => t.diveId.isIn(diveIds) & t.inputsHash.equals(inputsHash),
            ))
            .get();
    return {for (final row in rows) row.diveId: row.hadDeco};
  }

  Future<void> put(
    String diveId, {
    required bool hadDeco,
    required String inputsHash,
  }) async {
    await _db
        .into(_db.decoClassificationCache)
        .insertOnConflictUpdate(
          DecoClassificationCacheCompanion(
            diveId: Value(diveId),
            hadDeco: Value(hadDeco),
            inputsHash: Value(inputsHash),
            computedAt: Value(DateTime.now().millisecondsSinceEpoch),
          ),
        );
  }

  Future<void> clear() async {
    await _db.delete(_db.decoClassificationCache).go();
  }
}
