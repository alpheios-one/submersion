import 'package:submersion/core/utils/geo_math.dart';
import 'package:submersion/core/utils/lv95_transform.dart';
import 'package:submersion/features/bathymetry/data/sources/esri_ascii_parser.dart';
import 'package:submersion/features/bathymetry/domain/bathymetry_grid.dart';

/// Reprojects a swissBATHY3D ESRI ASCII grid into the app's WGS84-degree,
/// positive-down depth [BathymetryGrid].
///
/// Two things distinguish this from [EsriAsciiGridParser.parse]:
/// - The file's `xllcorner`/`yllcorner`/`cellsize` are LV95 METERS, not
///   WGS84 degrees, so the grid's origin and cell size must be reprojected
///   rather than copied through. Only the origin corner is reprojected via
///   [Lv95Transform] (a local affine approximation of degrees-per-meter at
///   that point) rather than every cell — over a single ~1 km tile this adds
///   negligible extra error on top of the transform's own ~1 m budget. The
///   per-degree conversion uses [metersPerDegreeLatitude] — the same
///   constant the dive_3d terrain builder uses to turn a grid's degrees
///   back into scene meters — so a stitched mosaic's cell spacing agrees
///   with how the 3D scene places the dive site marker on top of it; a
///   mismatch here previously left the site pin drifting outside the
///   rendered mesh.
///   Row/col ordering is untouched: both LV95 and WGS84 run (east, north).
/// - Values are LN02 heights above sea level for the LAKE BED, not already
///   relative to the local water surface — depth = [referenceLevelMeters]
///   (the lake's own mean level) minus the cell's elevation, per the task's
///   design decision.
BathymetryGrid parseSwissLv95Grid(
  String body, {
  required String sourceId,
  required DateTime fetchedAt,
  required double referenceLevelMeters,
}) => parseSwissLv95RawGrid(
  EsriAsciiGridParser.parseRaw(body),
  sourceId: sourceId,
  fetchedAt: fetchedAt,
  referenceLevelMeters: referenceLevelMeters,
);

/// Same reprojection/depth-conversion [parseSwissLv95Grid] does, taking an
/// already-parsed [RawEsriGrid] — the entry point used when the raw grid was
/// parsed once and then sliced with [extractRawEsriSubgrid] (a swissBATHY3D
/// STAC asset can cover an entire lake rather than a single tile, so the
/// same parsed raw grid is reused as the source for every tile it overlaps).
BathymetryGrid parseSwissLv95RawGrid(
  RawEsriGrid raw, {
  required String sourceId,
  required DateTime fetchedAt,
  required double referenceLevelMeters,
}) {
  final origin = Lv95Transform.toWgs84(
    raw.xll + raw.cellsize / 2,
    raw.yll + raw.cellsize / 2,
  );

  return BathymetryGrid(
    originLat: origin.latitude,
    originLon: origin.longitude,
    cellSizeLatDeg: raw.cellsize / metersPerDegreeLatitude,
    cellSizeLonDeg: raw.cellsize / metersPerDegreeLongitude(origin.latitude),
    rows: raw.nrows,
    cols: raw.ncols,
    depthsMeters: [
      for (final v in raw.values) v == null ? null : referenceLevelMeters - v,
    ],
    sourceId: sourceId,
    resolutionMeters: raw.cellsize,
    fetchedAt: fetchedAt,
  );
}

/// Extracts the rectangular sub-region of [raw] covering the half-open LV95
/// bounding box [minEasting]..[maxEasting] x [minNorthing]..[maxNorthing],
/// or null when the box does not overlap [raw] at all.
///
/// swissBATHY3D's STAC assets were assumed to be individual 1-km tiles, but
/// a live check found a single asset can cover an entire lake (e.g. one
/// "swissbathy3d_walensee" item/asset for the whole Walensee). Without this
/// extraction step, every 1-km tile coordinate within that lake resolved to
/// the exact same asset and therefore cached the exact same whole-lake grid
/// verbatim — the root cause of every dive site on that lake rendering an
/// identical mesh regardless of its actual location (bugs 5/6/7/9/10/11/12).
/// This slices out just the cells belonging to the requested tile before
/// [SwissBathy3dSource] caches and stitches it, so distinct tile coordinates
/// end up with distinct, location-correct content again.
RawEsriGrid? extractRawEsriSubgrid(
  RawEsriGrid raw, {
  required double minEasting,
  required double maxEasting,
  required double minNorthing,
  required double maxNorthing,
}) {
  int clampInt(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

  final colFrom = clampInt(
    ((minEasting - raw.xll) / raw.cellsize).floor(),
    0,
    raw.ncols,
  );
  final colTo = clampInt(
    ((maxEasting - raw.xll) / raw.cellsize).ceil(),
    0,
    raw.ncols,
  );
  // raw.values is south-first (row 0 = southernmost), matching northing.
  final rowFrom = clampInt(
    ((minNorthing - raw.yll) / raw.cellsize).floor(),
    0,
    raw.nrows,
  );
  final rowTo = clampInt(
    ((maxNorthing - raw.yll) / raw.cellsize).ceil(),
    0,
    raw.nrows,
  );
  if (colFrom >= colTo || rowFrom >= rowTo) return null;

  final subCols = colTo - colFrom;
  final subRows = rowTo - rowFrom;
  final values = List<double?>.filled(subRows * subCols, null);
  for (var r = 0; r < subRows; r++) {
    final srcRow = rowFrom + r;
    for (var c = 0; c < subCols; c++) {
      values[r * subCols + c] = raw.values[srcRow * raw.ncols + (colFrom + c)];
    }
  }

  return RawEsriGrid(
    ncols: subCols,
    nrows: subRows,
    xll: raw.xll + colFrom * raw.cellsize,
    yll: raw.yll + rowFrom * raw.cellsize,
    cellsize: raw.cellsize,
    values: values,
  );
}
