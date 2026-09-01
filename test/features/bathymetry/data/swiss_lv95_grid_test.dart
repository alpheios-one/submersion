import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/utils/geo_math.dart';
import 'package:submersion/core/utils/lv95_transform.dart';
import 'package:submersion/features/bathymetry/data/sources/swiss_lv95_grid.dart';
import 'package:submersion/features/dive_3d/domain/spatial/bathymetry_terrain_builder.dart';

void main() {
  final body = File(
    'test/fixtures/bathymetry/swissbathy3d_sample.asc',
  ).readAsStringSync();
  final when = DateTime.utc(2026, 8, 30);

  group('parseSwissLv95Grid', () {
    test(
      'reprojects LV95 meters to WGS84 degrees and applies the lake level',
      () {
        final grid = parseSwissLv95Grid(
          body,
          sourceId: 'swissbathy3d',
          fetchedAt: when,
          referenceLevelMeters: 406.1, // Zürichsee
        );

        expect(grid.rows, 4);
        expect(grid.cols, 4);
        expect(grid.sourceId, 'swissbathy3d');
        expect(grid.resolutionMeters, 100);

        // The origin must be plausible WGS84 degrees, not raw LV95 meters.
        expect(grid.originLat, inInclusiveRange(45.0, 48.0));
        expect(grid.originLon, inInclusiveRange(5.0, 11.0));

        // Cross-check the origin against a direct LV95 -> WGS84 conversion
        // of the same cell-center corner (xllcorner+cellsize/2, ...).
        final expectedOrigin = Lv95Transform.toWgs84(2685050, 1240050);
        expect(grid.originLat, closeTo(expectedOrigin.latitude, 1e-9));
        expect(grid.originLon, closeTo(expectedOrigin.longitude, 1e-9));

        // Southernmost data line (408.0 409.0 410.0 411.0) is grid row 0:
        // depth = 406.1 - 408.0 = -1.9.
        expect(grid.depthAt(0, 0), closeTo(-1.9, 1e-9));
        // Northernmost data line (400.0 399.0 398.0 397.0) is grid row 3:
        // depth = 406.1 - 400.0 = 6.1.
        expect(grid.depthAt(3, 0), closeTo(6.1, 1e-9));
        // nodata sentinel stays null.
        expect(grid.depthAt(1, 1), isNull);
      },
    );

    test('the latitude cell size shares the terrain builder\'s meters-per-'
        'degree constant, not an independent approximation', () {
      // Bug: an independently chosen conversion constant here (even one
      // off by under 1%) makes the grid's own idea of "how far apart are
      // my rows" disagree with how BathymetryTerrainBuilder later turns
      // those rows back into scene meters -- silently shifting a stitched
      // mosaic's true-world footprint away from where the 3D scene places
      // the dive site marker (always at the exact query coordinate).
      final grid = parseSwissLv95Grid(
        body,
        sourceId: 'swissbathy3d',
        fetchedAt: when,
        referenceLevelMeters: 406.1,
      );
      expect(
        grid.cellSizeLatDeg,
        closeTo(100.0 / BathymetryTerrainBuilder.metersPerDegLat, 1e-15),
      );
      expect(BathymetryTerrainBuilder.metersPerDegLat, metersPerDegreeLatitude);
    });

    test('a shore cell above the lake level becomes a negative depth', () {
      const aboveLakeLevel = '''
ncols 1
nrows 1
xllcorner 2685000
yllcorner 1240000
cellsize 100
nodata_value -9999
410.0
''';
      final grid = parseSwissLv95Grid(
        aboveLakeLevel,
        sourceId: 'swissbathy3d',
        fetchedAt: when,
        referenceLevelMeters: 406.1,
      );
      expect(grid.depthAt(0, 0), closeTo(406.1 - 410.0, 1e-9));
      expect(grid.depthAt(0, 0), lessThan(0));
    });
  });
}
