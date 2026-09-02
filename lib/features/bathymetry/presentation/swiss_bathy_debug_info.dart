// TEMPORARY - DEBUG ONLY, remove before upstream PR.
//
// Investigated the suspected root cause behind Bug 6/7/9 (two real,
// independently-meaningful dive sites at Walensee reportedly render a
// pixel-identical 3D mesh): [BathymetryRepository] used to share one cached
// grid across every coordinate inside its 0.02 degree quantized cell
// (roughly 2.2 km x 1.5 km at Swiss latitudes — wider than some lakes), so
// two sites closer together than that received the exact same fetch by
// design. Bug 10 made that quantization source-specific (see
// [BathymetryRepository.quantumDegFor]): inside a swissBATHY3D lake the raw
// coordinate is used as-is instead. This module recomputes, read-only and
// without any network call, the same coordinate/cache-key derivation the
// production pipeline performs, so that derivation is visible in the
// running app without a debugger.
import 'package:submersion/core/database/local_cache_database.dart';
import 'package:submersion/core/services/local_cache_database_service.dart';
import 'package:submersion/core/utils/lv95_transform.dart';
import 'package:submersion/features/bathymetry/data/bathymetry_repository.dart';
import 'package:submersion/features/bathymetry/data/bathymetry_resolver.dart';
import 'package:submersion/features/bathymetry/data/sources/swiss_bathy_tile_cache_repository.dart';
import 'package:submersion/features/bathymetry/data/sources/swiss_lake_levels.dart';
import 'package:submersion/features/bathymetry/data/sources/swiss_stac_client.dart';
import 'package:submersion/features/bathymetry/data/sources/swissbathy3d_source.dart';
import 'package:submersion/features/dive_sites/domain/entities/dive_site.dart';

/// One swissBATHY3D tile's cache status, for [SwissBathyDebugInfo.tiles].
class SwissBathyTileDebugInfo {
  final String tileKey;
  final bool cached;
  final DateTime? checkedAt;

  const SwissBathyTileDebugInfo({
    required this.tileKey,
    required this.cached,
    this.checkedAt,
  });
}

/// TEMPORARY - DEBUG ONLY, remove before upstream PR.
class SwissBathyDebugInfo {
  final String siteId;
  final String siteName;
  final GeoPoint siteCoordinate;

  /// The cell [BathymetryRepository.quantize] derives from [siteCoordinate]
  /// — the outer grid cache's actual sharing granularity. Equals
  /// [siteCoordinate] itself when [quantumDeg] is 0 (no coalescing).
  final ({double lat, double lon}) quantizedCell;

  /// The cache granularity actually applied to [siteCoordinate], per
  /// [BathymetryRepository.quantumDegFor]: 0 means no quantization (inside
  /// a swissBATHY3D lake), otherwise the standard 0.02 degree cell.
  final double quantumDeg;

  /// [BathymetryRepository.keyFor]'s cache key for [siteCoordinate]. Two
  /// sites with an identical value here share one cached [BathymetryGrid]
  /// row, byte for byte.
  final String outerCacheKey;

  /// The quantized cell's center — what the repository actually fetches
  /// around, per coordinate in the cell, not [siteCoordinate] itself.
  final GeoPoint fetchCenter;

  final bool insideSwissLakeCoverage;

  /// [fetchCenter] reprojected to LV95, or null outside lake coverage.
  final Lv95Coordinates? lv95;

  /// Every 1-km swissBATHY3D tile [SwissBathy3dSource.fetch] would request
  /// for [fetchCenter] at the resolver's default span, and whether each is
  /// already cached.
  final List<SwissBathyTileDebugInfo> tiles;

  /// The STAC items query URL for the first tile in [tiles], for a human to
  /// paste into a browser — built the same way [SwissStacClient.findAsset]
  /// builds it, without making the request.
  final String? firstTileStacUrl;

  const SwissBathyDebugInfo({
    required this.siteId,
    required this.siteName,
    required this.siteCoordinate,
    required this.quantizedCell,
    required this.quantumDeg,
    required this.outerCacheKey,
    required this.fetchCenter,
    required this.insideSwissLakeCoverage,
    required this.lv95,
    required this.tiles,
    required this.firstTileStacUrl,
  });
}

/// Builds a [SwissBathyDebugInfo] snapshot for [siteId]/[center]. Read-only:
/// issues no network requests and writes no cache rows, only re-derives
/// values and reads existing tile-cache rows (when the local cache database
/// is available; tile cache status is omitted otherwise).
Future<SwissBathyDebugInfo> buildSwissBathyDebugInfo({
  required String siteId,
  required String siteName,
  required GeoPoint center,
}) async {
  final quantum = BathymetryRepository.quantumDegFor(center);
  final cell = BathymetryRepository.quantize(center);
  final outerKey = BathymetryRepository.keyFor(center);
  final fetchCenter = quantum > 0
      ? GeoPoint(cell.lat + quantum / 2, cell.lon + quantum / 2)
      : center;

  final lake = findSwissLake(fetchCenter);
  if (lake == null) {
    return SwissBathyDebugInfo(
      siteId: siteId,
      siteName: siteName,
      siteCoordinate: center,
      quantizedCell: cell,
      quantumDeg: quantum,
      outerCacheKey: outerKey,
      fetchCenter: fetchCenter,
      insideSwissLakeCoverage: false,
      lv95: null,
      tiles: const [],
      firstTileStacUrl: null,
    );
  }

  final lv95 = Lv95Transform.fromWgs84(
    fetchCenter.latitude,
    fetchCenter.longitude,
  );
  const spanMeters = BathymetryResolver.defaultSpanMeters;
  const tileSize = SwissBathy3dSource.tileSizeMeters;
  const half = spanMeters / 2;
  final tileEMin = ((lv95.easting - half) / tileSize).floor();
  final tileEMax = ((lv95.easting + half) / tileSize).floor();
  final tileNMin = ((lv95.northing - half) / tileSize).floor();
  final tileNMax = ((lv95.northing + half) / tileSize).floor();

  LocalCacheDatabase? db;
  try {
    db = LocalCacheDatabaseService.instance.database;
  } on StateError {
    db = null;
  }
  final tileCache = db == null ? null : SwissBathyTileCacheRepository(db);

  final tiles = <SwissBathyTileDebugInfo>[];
  for (var n = tileNMin; n <= tileNMax; n++) {
    for (var e = tileEMin; e <= tileEMax; e++) {
      final tileKey = '${e}_$n';
      var cached = false;
      DateTime? checkedAt;
      if (tileCache != null) {
        final entry = await tileCache.read(tileKey);
        cached = entry != null;
        checkedAt = entry?.checkedAt;
      }
      tiles.add(
        SwissBathyTileDebugInfo(
          tileKey: tileKey,
          cached: cached,
          checkedAt: checkedAt,
        ),
      );
    }
  }

  final bbox = _tileBboxWgs84(tileEMin, tileNMin);
  final firstUrl =
      Uri.parse(
            'https://data.geo.admin.ch/api/stac/v1/collections/'
            '${SwissStacClient.collectionIds.first}/items',
          )
          .replace(
            queryParameters: {
              'bbox': bbox.map((v) => v.toString()).join(','),
              'limit': '10',
            },
          )
          .toString();

  return SwissBathyDebugInfo(
    siteId: siteId,
    siteName: siteName,
    siteCoordinate: center,
    quantizedCell: cell,
    quantumDeg: quantum,
    outerCacheKey: outerKey,
    fetchCenter: fetchCenter,
    insideSwissLakeCoverage: true,
    lv95: lv95,
    tiles: tiles,
    firstTileStacUrl: firstUrl,
  );
}

/// Mirrors [SwissBathy3dSource._tileBboxWgs84] (private there) so the URL
/// shown here matches exactly what a real fetch would query.
List<double> _tileBboxWgs84(int tileE, int tileN) {
  final sw = Lv95Transform.toWgs84(
    tileE * SwissBathy3dSource.tileSizeMeters,
    tileN * SwissBathy3dSource.tileSizeMeters,
  );
  final ne = Lv95Transform.toWgs84(
    (tileE + 1) * SwissBathy3dSource.tileSizeMeters,
    (tileN + 1) * SwissBathy3dSource.tileSizeMeters,
  );
  const epsilon = 0.0005;
  return [
    sw.longitude - epsilon,
    sw.latitude - epsilon,
    ne.longitude + epsilon,
    ne.latitude + epsilon,
  ];
}

/// Renders a [SwissBathyDebugInfo] as plain, copy-pasteable text.
String formatSwissBathyDebugInfo(SwissBathyDebugInfo info) {
  final buf = StringBuffer()
    ..writeln('DEBUG (temporary) - swissBATHY3D diagnostic')
    ..writeln('site: ${info.siteName} (${info.siteId})')
    ..writeln(
      'site coordinate (WGS84): '
      '${info.siteCoordinate.latitude}, ${info.siteCoordinate.longitude}',
    )
    ..writeln(
      'quantized cell (${info.quantumDeg}°'
      '${info.quantumDeg <= 0 ? ", i.e. unquantized/raw" : ""}): '
      '${info.quantizedCell.lat}, ${info.quantizedCell.lon}',
    )
    ..writeln('outer grid cache key: ${info.outerCacheKey}')
    ..writeln(
      info.quantumDeg <= 0
          ? 'fetch center (the site coordinate itself, unquantized): '
                '${info.fetchCenter.latitude}, ${info.fetchCenter.longitude}'
          : 'fetch center (cell center, NOT the site coordinate): '
                '${info.fetchCenter.latitude}, ${info.fetchCenter.longitude}',
    );
  if (!info.insideSwissLakeCoverage) {
    buf.write('outside known Swiss lake coverage (findSwissLake -> null)');
    return buf.toString();
  }
  buf.writeln(
    'LV95 (from fetch center): '
    'E=${info.lv95!.easting.toStringAsFixed(1)}, '
    'N=${info.lv95!.northing.toStringAsFixed(1)}',
  );
  buf.writeln('tiles requested (${info.tiles.length}):');
  for (final tile in info.tiles) {
    final checked = tile.checkedAt == null ? '' : ', checked ${tile.checkedAt}';
    buf.writeln(
      '  ${tile.tileKey}: ${tile.cached ? "cached" : "not cached"}$checked',
    );
  }
  if (info.firstTileStacUrl != null) {
    buf.write('first tile STAC query: ${info.firstTileStacUrl}');
  }
  return buf.toString();
}
