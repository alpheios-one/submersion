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
    final tileE = (lv95.easting / tileSizeMeters).floor();
    final tileN = (lv95.northing / tileSizeMeters).floor();
    final tileKey = '${tileE}_$tileN';

    final cached = await _tileCache.read(tileKey);
    if (cached != null) return cached;
    if (await _tileCache.hasCachedAnswer(tileKey)) {
      throw BathymetryFetchException(
        'no swissBATHY3D tile for $tileKey (cached negative)',
      );
    }

    final SwissBathyAsset? asset;
    final Uint8List zipBytes;
    try {
      asset = await _findAsset(_tileBboxWgs84(tileE, tileN));
      if (asset == null) {
        await _tileCache.writeEmpty(tileKey);
        throw BathymetryFetchException('no swissBATHY3D tile for $tileKey');
      }
      zipBytes = await _stac.downloadBytes(asset.href);
    } on BathymetryFetchException {
      rethrow;
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
      throw BathymetryFetchException(
        'swissBATHY3D asset for $tileKey had no ESRI ASCII grid file',
      );
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
