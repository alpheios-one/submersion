import 'dart:convert';

import 'package:drift/drift.dart';

import 'package:submersion/core/database/local_cache_database.dart';
import 'package:submersion/features/bathymetry/domain/bathymetry_grid.dart';

/// Cache-first access to one swissBATHY3D tile's parsed, depth-converted
/// grid, keyed by the LV95 1-km tile index (e.g. "2600_1200"). This is the
/// layer that guarantees a tile is downloaded and parsed only once, per the
/// task's OGD fair-use requirement — independent of, and finer-grained
/// than, the outer [BathymetryCache]'s 0.02 degree quantized cells.
class SwissBathyTileCacheRepository {
  final LocalCacheDatabase _db;

  const SwissBathyTileCacheRepository(this._db);

  /// The cached grid for [tileKey], or null when uncached OR when the tile
  /// is a cached negative ('empty'). Use [hasCachedAnswer] to tell those
  /// apart from "never looked up".
  Future<BathymetryGrid?> read(String tileKey) async {
    final row = await (_db.select(
      _db.swissBathyTileCache,
    )..where((t) => t.tileKey.equals(tileKey))).getSingleOrNull();
    if (row == null || row.status != 'ok') return null;
    final json = row.gridJson;
    if (json == null) return null;
    try {
      return BathymetryGrid.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (_) {
      return null; // corrupt row: caller re-derives and overwrites it
    }
  }

  /// Whether a definitive answer ('ok' or 'empty') is already cached for
  /// [tileKey]. False means "never resolved" or "a transient failure left
  /// no row" — both should retry.
  Future<bool> hasCachedAnswer(String tileKey) async {
    final row = await (_db.select(
      _db.swissBathyTileCache,
    )..where((t) => t.tileKey.equals(tileKey))).getSingleOrNull();
    return row != null;
  }

  Future<void> writeOk(String tileKey, BathymetryGrid grid) async {
    await _db
        .into(_db.swissBathyTileCache)
        .insertOnConflictUpdate(
          SwissBathyTileCacheCompanion.insert(
            tileKey: tileKey,
            status: 'ok',
            gridJson: Value(jsonEncode(grid.toJson())),
            fetchedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
  }

  Future<void> writeEmpty(String tileKey) async {
    await _db
        .into(_db.swissBathyTileCache)
        .insertOnConflictUpdate(
          SwissBathyTileCacheCompanion.insert(
            tileKey: tileKey,
            status: 'empty',
            fetchedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
  }
}
