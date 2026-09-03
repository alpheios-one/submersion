import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

import 'package:submersion/core/utils/lv95_transform.dart';
import 'package:submersion/features/bathymetry/data/sources/swiss_bathy_tile_cache_repository.dart';
import 'package:submersion/features/bathymetry/data/sources/swiss_lake_levels.dart';
import 'package:submersion/features/bathymetry/data/sources/swiss_lv95_grid.dart';
import 'package:submersion/features/bathymetry/data/sources/swiss_stac_client.dart';
import 'package:submersion/features/bathymetry/domain/bathymetry_grid.dart';
import 'package:submersion/features/bathymetry/domain/bathymetry_source.dart';
import 'package:submersion/features/dive_sites/domain/entities/dive_site.dart';

/// Regional tier: swisstopo swissBATHY3D lake-bed elevation model, via the
/// STAC API on data.geo.admin.ch (OGD, "Freie Nutzung, Quellenangabe ist
/// Pflicht" — attribution is Part 2's concern, not fetched here).
///
/// Z values in the source grid are heights above sea level (LN02), NOT
/// depths, and the grid itself is in LV95 meters, not WGS84 degrees —
/// [parseSwissLv95Grid] handles both conversions, using each lake's mean
/// water level from [swissLakeLevels].
///
/// Covers only the ~20 lakes in [swissLakeLevels] (a coordinate elsewhere in
/// Switzerland is dry land, out of scope for a bathymetry source). Each
/// covered coordinate maps to exactly one LV95 1-km tile, cached by
/// [SwissBathyTileCacheRepository] so a tile is fetched and parsed at most
/// once, per the OGD fair-use requirement.
class SwissBathy3dSource implements BathymetrySource {
  static const String sourceId = 'swissbathy3d';
  static const double tileSizeMeters = 1000;

  /// How long a cached tile is served without a freshness check. Chosen to
  /// keep the periodic check rare — swissBATHY3D lakes are re-surveyed on
  /// the order of years, not days — while still noticing an update within a
  /// bounded time. A stale tile still costs at most one light STAC item
  /// lookup, never a re-download unless the version actually changed (see
  /// [_refreshIfStale]), so this does not multiply the up-to-81-tile cost a
  /// single wide-span page view can already trigger (see fetch()).
  static const Duration staleCheckInterval = Duration(days: 30);

  /// Caps how many tiles are fetched or freshness-checked at once, in both
  /// [fetch]'s stitching loop and [refreshAllCachedTiles]'s sweep. A wide
  /// span can touch up to 81 tiles (see [staleCheckInterval]'s doc);
  /// fetching them strictly one at a time made a single page view painfully
  /// slow, but firing all of them at once would hammer the OGD server and
  /// violate its fair-use clause against excessive use just as surely as an
  /// unbounded download loop would. Bounded concurrency is the middle
  /// ground; this is a named constant rather than a magic number so both
  /// call sites stay in lockstep with each other and with the design intent.
  static const int maxConcurrentTileRequests = 4;

  final SwissStacClient _stac;
  final SwissBathyTileCacheRepository _tileCache;

  SwissBathy3dSource({
    required SwissBathyTileCacheRepository tileCache,
    http.Client? httpClient,
    SwissStacClient? stacClient,
  }) : _tileCache = tileCache,
       _stac = stacClient ?? SwissStacClient(client: httpClient);

  @override
  String get id => sourceId;

  @override
  bool get global => false;

  @override
  bool covers(GeoPoint center) => findSwissLake(center) != null;

  /// The LV95 1-km tile index (e.g. "2600_1200") containing [lv95].
  static String tileKeyFor(Lv95Coordinates lv95) {
    final tileE = (lv95.easting / tileSizeMeters).floor();
    final tileN = (lv95.northing / tileSizeMeters).floor();
    return '${tileE}_$tileN';
  }

  @override
  Future<BathymetryGrid> fetch(
    GeoPoint center, {
    required double spanMeters,
  }) async {
    final lake = findSwissLake(center);
    if (lake == null) {
      throw const BathymetryFetchException(
        'coordinate outside known Swiss lakes',
      );
    }

    final lv95 = Lv95Transform.fromWgs84(center.latitude, center.longitude);
    final half = spanMeters / 2;
    final tileEMin = ((lv95.easting - half) / tileSizeMeters).floor();
    final tileEMax = ((lv95.easting + half) / tileSizeMeters).floor();
    final tileNMin = ((lv95.northing - half) / tileSizeMeters).floor();
    final tileNMax = ((lv95.northing + half) / tileSizeMeters).floor();

    final tileCoords = <({int tileE, int tileN})>[
      for (var tileN = tileNMin; tileN <= tileNMax; tileN++)
        for (var tileE = tileEMin; tileE <= tileEMax; tileE++)
          (tileE: tileE, tileN: tileN),
    ];

    // Distinct 1-km tile coordinates can legitimately resolve to the exact
    // same STAC asset href (observed in production: a wide span's tile
    // range came back with an identical href across many of its bboxes,
    // per the per-tile diagnostic panel) -- memoized per fetch() call so
    // that shared asset's zip is downloaded over the network exactly once,
    // not once per tile coordinate that happens to resolve to it. This
    // does not change what each tile key ends up caching (still correctly
    // whatever the server resolved for it), only how many times the exact
    // same bytes are re-fetched, per the OGD fair-use requirement.
    final sharedDownloads = <String, Future<Uint8List>>{};

    // Bounded concurrency, not strictly sequential nor unbounded: up to
    // maxConcurrentTileRequests tiles in flight at once. Each is
    // cache-checked before any network call, so a warm cache stays cheap;
    // for a cold cache spanning dozens of tiles, this keeps a single page
    // view from either taking minutes (one at a time) or hammering the OGD
    // server with dozens of simultaneous requests.
    final results = await _runBounded(tileCoords, maxConcurrentTileRequests, (
      coord,
    ) async {
      try {
        return await _fetchTile(
          coord.tileE,
          coord.tileN,
          lake,
          sharedDownloads,
        );
      } on BathymetryFetchException {
        // One tile's transient failure (network timeout, a bad STAC
        // response) must not sink the whole stitched fetch when
        // neighboring tiles — possibly including the one under the dive
        // site itself — already succeeded (or are still in flight in
        // another worker). Treat it as a gap instead; never cached (see
        // _fetchTile), so the next visit retries just this tile. A span
        // can cover dozens of 1-km tiles, so this isolation matters far
        // more here than it did for the single-tile fetch this replaced.
        return null;
      }
    });
    final tiles = [for (final tile in results) ?tile];

    if (tiles.isEmpty) {
      throw BathymetryFetchException(
        'no swissBATHY3D tiles for tile range '
        'E[$tileEMin..$tileEMax] N[$tileNMin..$tileNMax]',
      );
    }
    return tiles.length == 1 ? tiles.single : _stitchTiles(tiles);
  }

  /// Fetches, parses and caches the single 1-km tile at ([tileE], [tileN]),
  /// or returns null when swissBATHY3D genuinely has no tile there (e.g. a
  /// shoreline cell outside the "complete tiles only" coverage) — a gap to
  /// stitch around, not an error. Transient failures (network, unparseable
  /// STAC response) still throw and are never cached, so the caller falls
  /// through to the next resolver tier and retries on the next visit.
  ///
  /// [sharedDownloads] memoizes the zip download by asset href across every
  /// tile in the same [fetch] call — see that method's doc — so two tile
  /// coordinates resolving to the same href share one network round trip
  /// instead of each downloading and parsing it independently.
  Future<BathymetryGrid?> _fetchTile(
    int tileE,
    int tileN,
    SwissLakeLevel lake,
    Map<String, Future<Uint8List>> sharedDownloads,
  ) async {
    final tileKey = '${tileE}_$tileN';

    final cached = await _tileCache.read(tileKey);
    if (cached != null) {
      if (!_isStale(cached.checkedAt)) return cached.grid;
      return _refreshIfStale(tileKey, tileE, tileN, lake, cached);
    }
    if (await _tileCache.hasCachedAnswer(tileKey)) return null;

    final SwissBathyAsset? asset;
    try {
      asset = await _findAsset(_tileBboxWgs84(tileE, tileN));
    } on SwissStacException catch (e) {
      // Transient: network error, HTTP failure, unparseable STAC response.
      // Must not be cached — the next visit should retry.
      throw BathymetryFetchException('swissBATHY3D fetch failed: $e');
    }
    if (asset == null) {
      await _tileCache.writeEmpty(tileKey);
      return null;
    }

    final resolvedAsset = asset;
    final Uint8List zipBytes;
    try {
      zipBytes = await sharedDownloads.putIfAbsent(
        resolvedAsset.href,
        () => _stac.downloadBytes(resolvedAsset.href),
      );
    } on SwissStacException catch (e) {
      throw BathymetryFetchException('swissBATHY3D fetch failed: $e');
    }

    final gridText = _extractGridText(zipBytes);
    if (gridText == null) {
      // Deterministic for this tile: caching it avoids re-downloading the
      // same zip on every future visit to the same coordinate.
      await _tileCache.writeEmpty(tileKey);
      return null;
    }

    final BathymetryGrid grid;
    try {
      grid = parseSwissLv95Grid(
        gridText,
        sourceId: sourceId,
        fetchedAt: DateTime.now(),
        referenceLevelMeters: lake.meanLevelMeters,
      );
    } on FormatException catch (e) {
      throw BathymetryFetchException('swissBATHY3D grid parse failed: $e');
    }
    await _tileCache.writeOk(tileKey, grid, sourceDatetime: asset.datetime);
    return grid;
  }

  static bool _isStale(DateTime? checkedAt) {
    if (checkedAt == null) return true;
    return DateTime.now().difference(checkedAt) >= staleCheckInterval;
  }

  /// Revalidates an expired cached tile with one light STAC item lookup (no
  /// asset download) and only re-downloads the zip when the item's version
  /// token actually changed. Any failure along the way — the metadata
  /// lookup itself, the re-download, or reparsing — falls back to serving
  /// the still-cached [cached] grid unchanged rather than propagating an
  /// error: a stale-but-present tile beats no tile, and per the fair-use
  /// requirement this must never turn into an unbounded re-download loop.
  Future<BathymetryGrid?> _refreshIfStale(
    String tileKey,
    int tileE,
    int tileN,
    SwissLakeLevel lake,
    SwissBathyTileCacheEntry cached,
  ) async {
    return (await _checkAndMaybeUpdate(
      tileKey,
      tileE,
      tileN,
      lake,
      cached,
    )).grid;
  }

  /// The same one-light-lookup, re-download-only-on-change check
  /// [_refreshIfStale] performs, but reporting which of the three outcomes
  /// happened rather than just the resulting grid — used by
  /// [refreshAllCachedTiles], the manual "reload map data" action, to build
  /// a summary of how many tiles were actually updated.
  Future<({BathymetryGrid? grid, _TileCheckOutcome outcome})>
  _checkAndMaybeUpdate(
    String tileKey,
    int tileE,
    int tileN,
    SwissLakeLevel lake,
    SwissBathyTileCacheEntry cached,
  ) async {
    final SwissBathyAsset? asset;
    try {
      asset = await _findAsset(_tileBboxWgs84(tileE, tileN));
    } on SwissStacException {
      // metadata lookup failed -- retry on next check
      return (grid: cached.grid, outcome: _TileCheckOutcome.failed);
    } on BathymetryFetchException {
      // no known collection id resolved right now
      return (grid: cached.grid, outcome: _TileCheckOutcome.failed);
    }

    if (asset == null || asset.datetime == cached.sourceDatetime) {
      // No newer survey published (a null item lookup is treated the same
      // way: nothing to update, not "delete this known-good tile") -- just
      // record that the check happened, so the next one is due again in
      // staleCheckInterval.
      await _tileCache.touch(tileKey, sourceDatetime: asset?.datetime);
      return (grid: cached.grid, outcome: _TileCheckOutcome.upToDate);
    }

    try {
      final zipBytes = await _stac.downloadBytes(asset.href);
      final gridText = _extractGridText(zipBytes);
      if (gridText == null) {
        await _tileCache.touch(tileKey, sourceDatetime: asset.datetime);
        return (grid: cached.grid, outcome: _TileCheckOutcome.upToDate);
      }
      final grid = parseSwissLv95Grid(
        gridText,
        sourceId: sourceId,
        fetchedAt: DateTime.now(),
        referenceLevelMeters: lake.meanLevelMeters,
      );
      await _tileCache.writeOk(tileKey, grid, sourceDatetime: asset.datetime);
      return (grid: grid, outcome: _TileCheckOutcome.updated);
    } on SwissStacException {
      return (grid: cached.grid, outcome: _TileCheckOutcome.failed);
    } on FormatException {
      return (grid: cached.grid, outcome: _TileCheckOutcome.failed);
    }
  }

  /// Immediately revalidates every currently cached tile's freshness,
  /// bypassing [staleCheckInterval] — the manual "reload map data" action's
  /// entry point. Reuses [_checkAndMaybeUpdate], the exact same light STAC
  /// item lookup with conditional re-download the periodic per-fetch check
  /// performs, so this never re-downloads a tile whose version has not
  /// actually changed. A tile whose check fails (offline, STAC error) keeps
  /// serving its existing cached grid unchanged, counted as
  /// [SwissBathyRefreshSummary.failed] rather than thrown — one failed tile
  /// must not abort the sweep over the rest, matching the fair-use
  /// requirement that a failed check never becomes a crash or a forced
  /// re-download loop. Uses the same [maxConcurrentTileRequests]-bounded
  /// concurrency as [fetch]'s tile-stitching loop, rather than an
  /// independent sequential or unbounded sweep, so a large cache (many
  /// visited lakes) revalidates quickly without exceeding the same
  /// fair-use-driven concurrency ceiling.
  Future<SwissBathyRefreshSummary> refreshAllCachedTiles() async {
    final tileKeys = await _tileCache.okTileKeys();

    final outcomes = await _runBounded(tileKeys, maxConcurrentTileRequests, (
      tileKey,
    ) async {
      final cached = await _tileCache.read(tileKey);
      if (cached == null) return null; // evicted/corrupted since listing

      final parts = tileKey.split('_');
      final tileE = parts.length == 2 ? int.tryParse(parts[0]) : null;
      final tileN = parts.length == 2 ? int.tryParse(parts[1]) : null;
      if (tileE == null || tileN == null) return null;

      final tileCenter = Lv95Transform.toWgs84(
        (tileE + 0.5) * tileSizeMeters,
        (tileN + 0.5) * tileSizeMeters,
      );
      final lake = findSwissLake(
        GeoPoint(tileCenter.latitude, tileCenter.longitude),
      );
      if (lake == null) return null; // should not happen for a real 'ok' tile

      final result = await _checkAndMaybeUpdate(
        tileKey,
        tileE,
        tileN,
        lake,
        cached,
      );
      return result.outcome;
    });

    var updated = 0;
    var upToDate = 0;
    var failed = 0;
    for (final outcome in outcomes) {
      switch (outcome) {
        case _TileCheckOutcome.updated:
          updated++;
        case _TileCheckOutcome.upToDate:
          upToDate++;
        case _TileCheckOutcome.failed:
          failed++;
        case null:
          break; // evicted, corrupted, or unparseable tile key: not counted
      }
    }
    return SwissBathyRefreshSummary(
      updated: updated,
      upToDate: upToDate,
      failed: failed,
    );
  }

  /// Merges same-resolution tile grids into one rectangular [BathymetryGrid]
  /// spanning all of them. Each tile's cells are placed by rounding its
  /// origin's offset from the merged origin to the nearest cell — robust to
  /// the sub-cell drift between tiles' independently-reprojected LV95
  /// origins (see [parseSwissLv95Grid]) — rather than assuming tiles are
  /// pixel-perfectly aligned. Gaps (no tile, or nodata cells) stay null.
  static BathymetryGrid _stitchTiles(List<BathymetryGrid> tiles) {
    final reference = tiles.first;
    final cellSizeLat = reference.cellSizeLatDeg;
    final cellSizeLon = reference.cellSizeLonDeg;

    var minLat = double.infinity;
    var maxLat = -double.infinity;
    var minLon = double.infinity;
    var maxLon = -double.infinity;
    for (final tile in tiles) {
      final tileMinLat = tile.originLat - cellSizeLat / 2;
      final tileMaxLat = tile.originLat + cellSizeLat * (tile.rows - 0.5);
      final tileMinLon = tile.originLon - cellSizeLon / 2;
      final tileMaxLon = tile.originLon + cellSizeLon * (tile.cols - 0.5);
      if (tileMinLat < minLat) minLat = tileMinLat;
      if (tileMaxLat > maxLat) maxLat = tileMaxLat;
      if (tileMinLon < minLon) minLon = tileMinLon;
      if (tileMaxLon > maxLon) maxLon = tileMaxLon;
    }

    final rows = ((maxLat - minLat) / cellSizeLat).round();
    final cols = ((maxLon - minLon) / cellSizeLon).round();
    final originLat = minLat + cellSizeLat / 2;
    final originLon = minLon + cellSizeLon / 2;

    final merged = List<double?>.filled(rows * cols, null);
    var fetchedAt = reference.fetchedAt;
    for (final tile in tiles) {
      if (tile.fetchedAt.isBefore(fetchedAt)) fetchedAt = tile.fetchedAt;
      final rowOffset = ((tile.originLat - originLat) / cellSizeLat).round();
      final colOffset = ((tile.originLon - originLon) / cellSizeLon).round();
      for (var r = 0; r < tile.rows; r++) {
        final mergedRow = rowOffset + r;
        if (mergedRow < 0 || mergedRow >= rows) continue;
        for (var c = 0; c < tile.cols; c++) {
          final mergedCol = colOffset + c;
          if (mergedCol < 0 || mergedCol >= cols) continue;
          final depth = tile.depthAt(r, c);
          if (depth != null) merged[mergedRow * cols + mergedCol] = depth;
        }
      }
    }

    return BathymetryGrid(
      originLat: originLat,
      originLon: originLon,
      cellSizeLatDeg: cellSizeLat,
      cellSizeLonDeg: cellSizeLon,
      rows: rows,
      cols: cols,
      depthsMeters: merged,
      sourceId: reference.sourceId,
      resolutionMeters: reference.resolutionMeters,
      fetchedAt: fetchedAt,
    );
  }

  /// Tries each candidate collection ID in turn, falling through to the
  /// next on a confirmed 404 (wrong ID) rather than failing outright.
  Future<SwissBathyAsset?> _findAsset(List<double> bbox) async {
    SwissStacCollectionNotFoundException? lastNotFound;
    for (final collectionId in SwissStacClient.collectionIds) {
      try {
        return await _stac.findAsset(collectionId: collectionId, bbox: bbox);
      } on SwissStacCollectionNotFoundException catch (e) {
        lastNotFound = e;
      }
    }
    throw BathymetryFetchException(
      'no known swissBATHY3D collection id resolved: $lastNotFound',
    );
  }

  static List<double> _tileBboxWgs84(int tileE, int tileN) {
    final sw = Lv95Transform.toWgs84(
      tileE * tileSizeMeters,
      tileN * tileSizeMeters,
    );
    final ne = Lv95Transform.toWgs84(
      (tileE + 1) * tileSizeMeters,
      (tileN + 1) * tileSizeMeters,
    );
    // Small buffer so a tile-edge coordinate reliably intersects the item's
    // own bbox despite the two approximation formulas' independent error.
    const epsilon = 0.0005;
    return [
      sw.longitude - epsilon,
      sw.latitude - epsilon,
      ne.longitude + epsilon,
      ne.latitude + epsilon,
    ];
  }

  /// The first `.asc`/`.grd` entry in the zip, or null when it contains only
  /// other formats (e.g. XYZ, which this source does not parse).
  static String? _extractGridText(Uint8List zipBytes) {
    final archive = ZipDecoder().decodeBytes(zipBytes);
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final lower = entry.name.toLowerCase();
      if (lower.endsWith('.asc') || lower.endsWith('.grd')) {
        return utf8.decode(entry.readBytes() ?? const [], allowMalformed: true);
      }
    }
    return null;
  }
}

/// Runs [task] over [items] with at most [maxConcurrent] running at once —
/// a small work-stealing pool, not a fixed batch-of-N-then-wait loop, so a
/// worker that finishes an early, cache-hit item immediately picks up the
/// next one instead of sitting idle until the slowest item in its batch
/// completes. Each result keeps its input's position in the returned list.
/// [task] is expected to handle its own errors (as every caller in this
/// file does): one item failing must never affect any other item's
/// in-flight or still-pending work.
Future<List<T>> _runBounded<S, T>(
  List<S> items,
  int maxConcurrent,
  Future<T> Function(S item) task,
) async {
  final results = List<T?>.filled(items.length, null);
  var nextIndex = 0;

  Future<void> worker() async {
    while (true) {
      final index = nextIndex;
      if (index >= items.length) return;
      nextIndex++;
      results[index] = await task(items[index]);
    }
  }

  final workerCount = maxConcurrent < items.length
      ? maxConcurrent
      : items.length;
  await Future.wait(List.generate(workerCount, (_) => worker()));
  return results.cast<T>();
}

/// The result of one tile's freshness check in [SwissBathy3dSource._checkAndMaybeUpdate].
enum _TileCheckOutcome { updated, upToDate, failed }

/// Tally of a [SwissBathy3dSource.refreshAllCachedTiles] sweep, for the
/// manual "reload map data" action's confirmation message.
class SwissBathyRefreshSummary {
  /// Tiles whose STAC version had genuinely changed and were re-downloaded.
  final int updated;

  /// Tiles checked and confirmed to already be the latest version.
  final int upToDate;

  /// Tiles whose check itself failed (offline, STAC error) — these kept
  /// serving their existing cached grid unchanged, never counted as an
  /// error the user needs to act on.
  final int failed;

  const SwissBathyRefreshSummary({
    required this.updated,
    required this.upToDate,
    required this.failed,
  });

  /// Total tiles that were cached at the start of the sweep.
  int get total => updated + upToDate + failed;
}
