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

    // Sequential, not parallel: each tile is cache-checked before any
    // network call, and most requests hit the cache after the first visit
    // to an area — no benefit in racing STAC lookups for a cold cache.
    final tiles = <BathymetryGrid>[];
    for (var tileN = tileNMin; tileN <= tileNMax; tileN++) {
      for (var tileE = tileEMin; tileE <= tileEMax; tileE++) {
        final tile = await _fetchTile(tileE, tileN, lake);
        if (tile != null) tiles.add(tile);
      }
    }

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
  Future<BathymetryGrid?> _fetchTile(
    int tileE,
    int tileN,
    SwissLakeLevel lake,
  ) async {
    final tileKey = '${tileE}_$tileN';

    final cached = await _tileCache.read(tileKey);
    if (cached != null) return cached;
    if (await _tileCache.hasCachedAnswer(tileKey)) return null;

    final SwissBathyAsset? asset;
    final Uint8List zipBytes;
    try {
      asset = await _findAsset(_tileBboxWgs84(tileE, tileN));
      if (asset == null) {
        await _tileCache.writeEmpty(tileKey);
        return null;
      }
      zipBytes = await _stac.downloadBytes(asset.href);
    } on SwissStacException catch (e) {
      // Transient: network error, HTTP failure, unparseable STAC response.
      // Must not be cached — the next visit should retry.
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
    await _tileCache.writeOk(tileKey, grid);
    return grid;
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
