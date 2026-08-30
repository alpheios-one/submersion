import 'package:submersion/features/dive_sites/domain/entities/dive_site.dart';

/// A Swiss lake's mean water level, used to turn a swissBATHY3D lake-bed
/// elevation (LN02, meters above sea level) into a depth: depth = level - Z.
/// [box] is a generous WGS84 bounding box around the lake's shoreline —
/// coarser than the real shoreline on purpose, since a false-positive match
/// just costs one wasted STAC lookup that then finds no tile.
class SwissLakeLevel {
  final String name;

  /// Mean water level in meters above sea level (LN02). At border lakes
  /// (Bodensee, Genfersee, Lago Maggiore) this is the Swiss reference gauge,
  /// per the task's design decision.
  final double meanLevelMeters;
  final double minLat;
  final double maxLat;
  final double minLon;
  final double maxLon;

  const SwissLakeLevel({
    required this.name,
    required this.meanLevelMeters,
    required this.minLat,
    required this.maxLat,
    required this.minLon,
    required this.maxLon,
  });

  bool containsApprox(GeoPoint p) =>
      p.latitude >= minLat &&
      p.latitude <= maxLat &&
      p.longitude >= minLon &&
      p.longitude <= maxLon;
}

/// Static table of Swiss lakes covered by swissBATHY3D, with their mean
/// water level. Deliberately NOT a database table (per task design decision)
/// so a new lake or a corrected level ships as a code change, no migration.
///
/// REVIEWER WARNING: these mean-level figures are approximate values from
/// general geographic knowledge, not a network fetch of BAFU hydrological
/// data (no network access was available while writing this table). Verify
/// every value against the official BAFU gauge data
/// (https://www.hydrodaten.admin.ch) before relying on computed depths.
const List<SwissLakeLevel> swissLakeLevels = [
  SwissLakeLevel(
    name: 'Genfersee (Lac Léman)',
    meanLevelMeters: 372.0,
    minLat: 46.20,
    maxLat: 46.51,
    minLon: 6.14,
    maxLon: 6.93,
  ),
  SwissLakeLevel(
    name: 'Bodensee (Obersee)',
    meanLevelMeters: 395.2,
    minLat: 47.50,
    maxLat: 47.72,
    minLon: 9.05,
    maxLon: 9.70,
  ),
  SwissLakeLevel(
    name: 'Neuenburgersee',
    meanLevelMeters: 429.4,
    minLat: 46.75,
    maxLat: 47.10,
    minLon: 6.66,
    maxLon: 7.10,
  ),
  SwissLakeLevel(
    name: 'Vierwaldstättersee',
    meanLevelMeters: 433.6,
    minLat: 46.92,
    maxLat: 47.13,
    minLon: 8.30,
    maxLon: 8.65,
  ),
  SwissLakeLevel(
    name: 'Zürichsee',
    meanLevelMeters: 406.1,
    minLat: 47.13,
    maxLat: 47.36,
    minLon: 8.55,
    maxLon: 8.85,
  ),
  SwissLakeLevel(
    name: 'Zugersee',
    meanLevelMeters: 413.6,
    minLat: 47.10,
    maxLat: 47.23,
    minLon: 8.44,
    maxLon: 8.53,
  ),
  SwissLakeLevel(
    name: 'Thunersee',
    meanLevelMeters: 558.0,
    minLat: 46.63,
    maxLat: 46.75,
    minLon: 7.63,
    maxLon: 7.87,
  ),
  SwissLakeLevel(
    name: 'Brienzersee',
    meanLevelMeters: 564.0,
    minLat: 46.66,
    maxLat: 46.76,
    minLon: 7.86,
    maxLon: 8.08,
  ),
  SwissLakeLevel(
    name: 'Bielersee',
    meanLevelMeters: 429.3,
    minLat: 47.02,
    maxLat: 47.16,
    minLon: 7.05,
    maxLon: 7.25,
  ),
  SwissLakeLevel(
    name: 'Walensee',
    meanLevelMeters: 419.1,
    minLat: 47.10,
    maxLat: 47.18,
    minLon: 9.13,
    maxLon: 9.35,
  ),
  SwissLakeLevel(
    name: 'Lago Maggiore (Schweizer Referenz)',
    meanLevelMeters: 193.5,
    minLat: 45.82,
    maxLat: 46.17,
    minLon: 8.60,
    maxLon: 8.90,
  ),
  SwissLakeLevel(
    name: 'Lago di Lugano',
    meanLevelMeters: 271.0,
    minLat: 45.85,
    maxLat: 46.05,
    minLon: 8.85,
    maxLon: 9.10,
  ),
  SwissLakeLevel(
    name: 'Greifensee',
    meanLevelMeters: 435.4,
    minLat: 47.32,
    maxLat: 47.39,
    minLon: 8.65,
    maxLon: 8.72,
  ),
  SwissLakeLevel(
    name: 'Hallwilersee',
    meanLevelMeters: 449.0,
    minLat: 47.24,
    maxLat: 47.32,
    minLon: 8.19,
    maxLon: 8.24,
  ),
  SwissLakeLevel(
    name: 'Baldeggersee',
    meanLevelMeters: 463.5,
    minLat: 47.18,
    maxLat: 47.23,
    minLon: 8.24,
    maxLon: 8.29,
  ),
  SwissLakeLevel(
    name: 'Sempachsee',
    meanLevelMeters: 504.0,
    minLat: 47.10,
    maxLat: 47.16,
    minLon: 8.13,
    maxLon: 8.20,
  ),
  SwissLakeLevel(
    name: 'Pfäffikersee',
    meanLevelMeters: 537.0,
    minLat: 47.34,
    maxLat: 47.38,
    minLon: 8.77,
    maxLon: 8.82,
  ),
  SwissLakeLevel(
    name: 'Ägerisee',
    meanLevelMeters: 724.0,
    minLat: 47.11,
    maxLat: 47.16,
    minLon: 8.60,
    maxLon: 8.65,
  ),
  SwissLakeLevel(
    name: 'Murtensee',
    meanLevelMeters: 429.4,
    minLat: 46.88,
    maxLat: 46.96,
    minLon: 7.05,
    maxLon: 7.14,
  ),
  SwissLakeLevel(
    name: 'Sarnersee',
    meanLevelMeters: 469.5,
    minLat: 46.85,
    maxLat: 46.92,
    minLon: 8.20,
    maxLon: 8.26,
  ),
];

/// The lake whose bounding box contains [p], or null when none matches
/// (the coordinate is outside all known swissBATHY3D lakes).
SwissLakeLevel? findSwissLake(GeoPoint p) {
  for (final lake in swissLakeLevels) {
    if (lake.containsApprox(p)) return lake;
  }
  return null;
}
