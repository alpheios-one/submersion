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

  /// Every stored entry for [diveIds], keyed by dive id, in a single query.
  ///
  /// Deliberately returns the stored `inputsHash` rather than filtering on it
  /// in SQL: each dive has its own fingerprint (their `updated_at` differ), so
  /// a hash-filtered query would need one round trip per dive. The caller
  /// compares hashes in Dart, which keeps this to one round trip for the whole
  /// batch and leaves the staleness policy in one place.
  Future<Map<String, ({bool hadDeco, String inputsHash})>> getEntries(
    Set<String> diveIds,
  ) async {
    if (diveIds.isEmpty) return const {};
    final rows = await (_db.select(
      _db.decoClassificationCache,
    )..where((t) => t.diveId.isIn(diveIds))).get();
    return {
      for (final row in rows)
        row.diveId: (hadDeco: row.hadDeco, inputsHash: row.inputsHash),
    };
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
