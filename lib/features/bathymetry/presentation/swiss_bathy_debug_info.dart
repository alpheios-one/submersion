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
import 'dart:typed_data';

import 'package:submersion/core/database/local_cache_database.dart';
import 'package:submersion/core/services/local_cache_database_service.dart';
import 'package:submersion/core/utils/lv95_transform.dart';
import 'package:submersion/features/bathymetry/data/bathymetry_repository.dart';
import 'package:submersion/features/bathymetry/data/bathymetry_resolver.dart';
import 'package:submersion/features/bathymetry/data/sources/swiss_bathy_tile_cache_repository.dart';
import 'package:submersion/features/bathymetry/data/sources/swiss_lake_levels.dart';
import 'package:submersion/features/bathymetry/data/sources/swiss_stac_client.dart';
import 'package:submersion/features/bathymetry/data/sources/swissbathy3d_source.dart';
import 'package:submersion/features/bathymetry/domain/bathymetry_grid.dart';
import 'package:submersion/features/dive_3d/domain/entities/mesh_data.dart';
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

// ---------------------------------------------------------------------
// TEMPORARY - DEBUG ONLY, remove before upstream PR.
//
// Investigated Bug 11 (two real, independently-meaningful dive sites
// reportedly render a pixel-identical visible 3D profile even though the
// fetch/stitch layer above was proven, with the real coordinates, to
// return different grids). Everything above this point diagnoses the
// FETCH layer; this section instead fingerprints the RENDER layer —
// the actual [MeshData] a [SiteSeascapeGeometryService.buildWithLabels]
// call hands to [Scene3d] — plus records when that call last actually ran
// for a given site, so a stale/reused Scene3d (rather than a stale/reused
// grid) can be told apart from a genuine rebuild that just happens to
// produce the same numbers.
// ---------------------------------------------------------------------

/// TEMPORARY - DEBUG ONLY, remove before upstream PR. Timestamp of the
/// last [SiteSeascapeGeometryService.buildWithLabels] call per site id,
/// written by the caller in `site_seascape_providers.dart` right after
/// `built` resolves (both the synchronous and the `compute()`-isolate
/// branch funnel through that one call site back on the main isolate).
/// A plain module-level map is enough here: this is throwaway diagnostic
/// state for a single debugging session, not app state.
final Map<String, DateTime> _swissBathyDebugLastBuiltAt = {};

/// TEMPORARY - DEBUG ONLY, remove before upstream PR.
void recordSwissBathySceneBuilt(String siteId) {
  _swissBathyDebugLastBuiltAt[siteId] = DateTime.now();
}

/// TEMPORARY - DEBUG ONLY, remove before upstream PR.
DateTime? swissBathyDebugLastBuiltAtFor(String siteId) =>
    _swissBathyDebugLastBuiltAt[siteId];

/// TEMPORARY - DEBUG ONLY, remove before upstream PR. A cheap, order- and
/// value-sensitive fingerprint of a mesh's flat position buffer, plus when
/// the scene that produced it was last (re)built for [siteId] — everything
/// needed to tell "two sites really did render the same triangles" apart
/// from "the mesh differs but happens to look the same" without shipping
/// the whole array.
///
/// [MeshData.positions] is a flat xyz triplet buffer, but in this codebase's
/// scene frame ([BathymetryTerrainBuilder.build]) the VERTICAL axis a diver
/// reads as depth is the middle component (`positions[vi + 1]`, scene Y —
/// `projection.yOf(depth)`), not the third one: the third component is
/// scene Z, `projection.zOf(north)`, a HORIZONTAL axis. [depthHash] and
/// [horizontalHash] split on that real axis assignment (not on a naive
/// "every third value starting at 2" reading of "xyz"), so they actually
/// test the Bug-11 hypothesis that two sites' identical-looking renders
/// might share depth/color values while differing only in the horizontal
/// placement of those values.
class SwissBathyRenderFingerprint {
  final String siteId;
  final int vertexCount;
  final List<double> firstPositions;
  final List<double> lastPositions;

  /// FNV-1a over the position buffer's raw bytes. Two fingerprints with
  /// the same [vertexCount] but a different [hash] are proof the meshes
  /// differ even if the first/last samples happen to match.
  final int hash;

  /// FNV-1a over ONLY the depth/vertical component of every vertex
  /// (`positions[vi + 1]`, scene Y). If this matches across two sites while
  /// [horizontalHash] differs, the two renders use the same depth/color
  /// values at different horizontal positions — exactly the "identical
  /// noise pattern, different footprint" symptom Bug 11 describes.
  final int depthHash;

  /// FNV-1a over ONLY the horizontal components of every vertex
  /// (`positions[vi]` scene X / east and `positions[vi + 2]` scene Z /
  /// north, interleaved in that order). The complement of [depthHash].
  final int horizontalHash;
  final DateTime? lastBuiltAt;

  const SwissBathyRenderFingerprint({
    required this.siteId,
    required this.vertexCount,
    required this.firstPositions,
    required this.lastPositions,
    required this.hash,
    required this.depthHash,
    required this.horizontalHash,
    required this.lastBuiltAt,
  });
}

/// TEMPORARY - DEBUG ONLY, remove before upstream PR. Builds a
/// [SwissBathyRenderFingerprint] for the terrain mesh currently on screen
/// for [siteId] — read-only, no recomputation of the mesh itself.
SwissBathyRenderFingerprint buildSwissBathyRenderFingerprint({
  required String siteId,
  required MeshData mesh,
}) {
  final positions = mesh.positions;
  final firstCount = positions.length < 3 ? positions.length : 3;
  final lastStart = positions.length < 3 ? 0 : positions.length - 3;
  return SwissBathyRenderFingerprint(
    siteId: siteId,
    vertexCount: mesh.vertexCount,
    firstPositions: positions.sublist(0, firstCount).toList(),
    lastPositions: positions.sublist(lastStart).toList(),
    hash: _fnv1aHashBytes(_bytesOf(positions)),
    depthHash: _fnv1aHashBytes(
      _bytesOf(_extractPositionComponent(positions, 1)),
    ),
    horizontalHash: _fnv1aHashBytes(
      _bytesOf(_extractHorizontalComponents(positions)),
    ),
    lastBuiltAt: swissBathyDebugLastBuiltAtFor(siteId),
  );
}

/// TEMPORARY - DEBUG ONLY, remove before upstream PR. Pulls the single
/// component at [offset] (0 = scene X/east, 1 = scene Y/depth, 2 = scene
/// Z/north — see [SwissBathyRenderFingerprint]'s doc for why 1, not 2, is
/// the depth axis) out of every xyz triplet in [positions].
Float32List _extractPositionComponent(Float32List positions, int offset) {
  final count = positions.length ~/ 3;
  final out = Float32List(count);
  for (var i = 0; i < count; i++) {
    out[i] = positions[i * 3 + offset];
  }
  return out;
}

/// TEMPORARY - DEBUG ONLY, remove before upstream PR. Pulls both horizontal
/// components (scene X/east, scene Z/north) out of every xyz triplet in
/// [positions], interleaved as [x0, z0, x1, z1, ...] — the complement of
/// [_extractPositionComponent] at offset 1.
Float32List _extractHorizontalComponents(Float32List positions) {
  final count = positions.length ~/ 3;
  final out = Float32List(count * 2);
  for (var i = 0; i < count; i++) {
    out[i * 2] = positions[i * 3];
    out[i * 2 + 1] = positions[i * 3 + 2];
  }
  return out;
}

/// TEMPORARY - DEBUG ONLY, remove before upstream PR. A cheap fingerprint
/// (hash plus min/max/null-count) of the raw [BathymetryGrid]
/// [SiteSeascapeGeometryService.buildWithLabels] receives as input — the
/// grid [SwissBathy3dSource.fetch] returned (stitched across tiles, when
/// the site's span touched more than one), BEFORE any terrain-mesh
/// projection. Sits one layer upstream of [SwissBathyRenderFingerprint]: if
/// two sites' grid fingerprints already match here, the bug is in the fetch
/// layer or something feeding [SiteSeascapeInput.grid] a shared instance —
/// not in the depth/color mapping done while building the mesh.
class SwissBathyGridFingerprint {
  final int rows;
  final int cols;
  final double? minDepth;
  final double? maxDepth;
  final int nullCount;

  /// FNV-1a over every cell's raw depth (LN02-derived meters, `null` cells
  /// folded in as a fixed NaN bit pattern so a run of nodata still moves
  /// the hash instead of being silently skipped).
  final int hash;

  const SwissBathyGridFingerprint({
    required this.rows,
    required this.cols,
    required this.minDepth,
    required this.maxDepth,
    required this.nullCount,
    required this.hash,
  });
}

/// TEMPORARY - DEBUG ONLY, remove before upstream PR. Builds a
/// [SwissBathyGridFingerprint] for [grid] — read-only, no re-fetch.
SwissBathyGridFingerprint buildSwissBathyGridFingerprint(BathymetryGrid grid) {
  double? minDepth;
  double? maxDepth;
  var nullCount = 0;
  final cells = Float64List(grid.depthsMeters.length);
  for (var i = 0; i < grid.depthsMeters.length; i++) {
    final d = grid.depthsMeters[i];
    if (d == null) {
      nullCount++;
      cells[i] = double.nan;
      continue;
    }
    cells[i] = d;
    if (minDepth == null || d < minDepth) minDepth = d;
    if (maxDepth == null || d > maxDepth) maxDepth = d;
  }
  return SwissBathyGridFingerprint(
    rows: grid.rows,
    cols: grid.cols,
    minDepth: minDepth,
    maxDepth: maxDepth,
    nullCount: nullCount,
    hash: _fnv1aHashBytes(_bytesOf(cells)),
  );
}

/// TEMPORARY - DEBUG ONLY, remove before upstream PR. Raw bytes backing a
/// typed-data view, for hashing without any double->string rounding loss.
Uint8List _bytesOf(TypedData values) =>
    values.buffer.asUint8List(values.offsetInBytes, values.lengthInBytes);

/// TEMPORARY - DEBUG ONLY, remove before upstream PR. FNV-1a folded over
/// raw bytes rather than the source double values, so it is exact (no
/// rounding/formatting loss) and cheap enough to run on a tap.
int _fnv1aHashBytes(Uint8List bytes) {
  var hash = 0x811c9dc5;
  for (final b in bytes) {
    hash ^= b;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

/// TEMPORARY - DEBUG ONLY, remove before upstream PR. Renders a
/// [SwissBathyRenderFingerprint] as plain, copy-pasteable text, appended
/// below [formatSwissBathyDebugInfo]'s fetch-layer output.
String formatSwissBathyRenderFingerprint(SwissBathyRenderFingerprint fp) {
  final buf = StringBuffer()
    ..writeln('--- render layer (temporary) ---')
    ..writeln('vertexCount: ${fp.vertexCount}')
    ..writeln('positions[0:3]: ${fp.firstPositions}')
    ..writeln('positions[-3:]: ${fp.lastPositions}')
    ..writeln('positions hash (fnv1a32): 0x${fp.hash.toRadixString(16)}')
    ..writeln(
      'depth-only hash (scene Y, positions[vi+1]) (fnv1a32): '
      '0x${fp.depthHash.toRadixString(16)}',
    )
    ..writeln(
      'horizontal-only hash (scene X+Z, positions[vi]+positions[vi+2]) '
      '(fnv1a32): 0x${fp.horizontalHash.toRadixString(16)}',
    )
    ..write(
      'buildWithLabels() last ran for this site: '
      '${fp.lastBuiltAt?.toIso8601String() ?? "not recorded yet"}',
    );
  return buf.toString();
}

/// TEMPORARY - DEBUG ONLY, remove before upstream PR. Renders a
/// [SwissBathyGridFingerprint] as plain, copy-pasteable text, appended
/// below [formatSwissBathyRenderFingerprint]'s output.
String formatSwissBathyGridFingerprint(SwissBathyGridFingerprint fp) {
  final buf = StringBuffer()
    ..writeln('--- raw stitched grid (temporary) ---')
    ..writeln('rows x cols: ${fp.rows} x ${fp.cols}')
    ..writeln(
      'depth min/max: ${fp.minDepth?.toStringAsFixed(2) ?? "n/a"} / '
      '${fp.maxDepth?.toStringAsFixed(2) ?? "n/a"}',
    )
    ..writeln('nodata cells: ${fp.nullCount} / ${fp.rows * fp.cols}')
    ..write('grid depths hash (fnv1a32): 0x${fp.hash.toRadixString(16)}');
  return buf.toString();
}
