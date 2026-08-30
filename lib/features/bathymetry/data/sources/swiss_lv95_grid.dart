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
///   negligible extra error on top of the transform's own ~1 m budget.
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
}) {
  final raw = EsriAsciiGridParser.parseRaw(body);
  final origin = Lv95Transform.toWgs84(
    raw.xll + raw.cellsize / 2,
    raw.yll + raw.cellsize / 2,
  );

  return BathymetryGrid(
    originLat: origin.latitude,
    originLon: origin.longitude,
    cellSizeLatDeg: raw.cellsize / 111320.0,
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
