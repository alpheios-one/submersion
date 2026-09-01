import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:submersion/core/database/local_cache_database.dart';
import 'package:submersion/core/utils/lv95_transform.dart';
import 'package:submersion/features/bathymetry/data/bathymetry_resolver.dart';
import 'package:submersion/features/bathymetry/data/sources/swiss_bathy_tile_cache_repository.dart';
import 'package:submersion/features/bathymetry/data/sources/swiss_stac_client.dart';
import 'package:submersion/features/bathymetry/data/sources/swissbathy3d_source.dart';
import 'package:submersion/features/bathymetry/domain/bathymetry_grid.dart';
import 'package:submersion/features/bathymetry/domain/bathymetry_source.dart';
import 'package:submersion/features/dive_3d/domain/spatial/bathymetry_terrain_builder.dart';
import 'package:submersion/features/dive_sites/domain/entities/dive_site.dart';

Uint8List _zipOf(String entryName, String content) {
  final archive = Archive();
  final bytes = utf8.encode(content);
  archive.addFile(ArchiveFile(entryName, bytes.length, bytes));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// Echoes the request's own `bbox` query parameter back as the mocked STAC
/// feature's `bbox`, so these fixtures satisfy [SwissStacClient]'s overlap
/// check the same way a real, spatially-honest server response would.
List<double> _requestedBbox(http.Request req) =>
    req.url.queryParameters['bbox']!.split(',').map(double.parse).toList();

void main() {
  final gridBody = File(
    'test/fixtures/bathymetry/swissbathy3d_sample.asc',
  ).readAsStringSync();
  // Inside Zürichsee's bounding box (see swiss_lake_levels.dart).
  const zurichseePoint = GeoPoint(47.25, 8.65);
  const alpsPoint = GeoPoint(46.55, 7.98); // not near any listed lake

  late LocalCacheDatabase db;

  setUp(() {
    db = LocalCacheDatabase(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  SwissBathy3dSource buildSource(
    Future<http.Response> Function(http.Request) handler,
  ) => SwissBathy3dSource(
    tileCache: SwissBathyTileCacheRepository(db),
    stacClient: SwissStacClient(client: MockClient(handler)),
  );

  group('SwissBathy3dSource.covers', () {
    test('true inside a known lake bounding box', () {
      final source = buildSource((_) async => http.Response('', 404));
      expect(source.covers(zurichseePoint), isTrue);
    });

    test('false outside every known lake', () {
      final source = buildSource((_) async => http.Response('', 404));
      expect(source.covers(alpsPoint), isFalse);
    });
  });

  group('SwissBathy3dSource.fetch', () {
    test('throws without any HTTP call outside known lakes', () async {
      var calls = 0;
      final source = buildSource((_) async {
        calls++;
        return http.Response('', 404);
      });
      expect(
        () => source.fetch(alpsPoint, spanMeters: 1000),
        throwsA(isA<BathymetryFetchException>()),
      );
      expect(calls, 0);
    });

    test(
      'downloads, unzips, reprojects and caches the tile on first fetch',
      () async {
        var itemCalls = 0;
        var downloadCalls = 0;
        final source = buildSource((req) async {
          if (req.url.path.endsWith('/items')) {
            itemCalls++;
            return http.Response(
              jsonEncode({
                'features': [
                  {
                    'bbox': _requestedBbox(req),
                    'assets': {
                      'grid': {'href': 'https://example.org/tile_grid.zip'},
                    },
                  },
                ],
              }),
              200,
            );
          }
          downloadCalls++;
          return http.Response.bytes(_zipOf('tile.asc', gridBody), 200);
        });

        // A span well under a tile width keeps this to the single tile
        // under zurichseePoint; multi-tile stitching has its own tests
        // below.
        final grid = await source.fetch(zurichseePoint, spanMeters: 100);
        expect(grid.sourceId, 'swissbathy3d');
        expect(grid.rows, 4);
        expect(itemCalls, 1);
        expect(downloadCalls, 1);

        // Second fetch of a coordinate in the same tile must hit neither
        // the STAC API nor the download endpoint again (tile-level cache).
        final again = await source.fetch(zurichseePoint, spanMeters: 100);
        expect(again.sourceId, 'swissbathy3d');
        expect(itemCalls, 1);
        expect(downloadCalls, 1);
      },
    );

    test(
      'caches a definitive "no tile" answer and never re-queries it',
      () async {
        var itemCalls = 0;
        final source = buildSource((req) async {
          itemCalls++;
          return http.Response(jsonEncode({'features': []}), 200);
        });

        await expectLater(
          source.fetch(zurichseePoint, spanMeters: 100),
          throwsA(isA<BathymetryFetchException>()),
        );
        expect(itemCalls, 1);

        await expectLater(
          source.fetch(zurichseePoint, spanMeters: 100),
          throwsA(isA<BathymetryFetchException>()),
        );
        // The negative answer was cached by tile key: no second STAC call.
        expect(itemCalls, 1);
      },
    );

    test(
      'a collection-not-found response surfaces as a fetch exception',
      () async {
        final source = buildSource((_) async => http.Response('nope', 404));
        expect(
          () => source.fetch(zurichseePoint, spanMeters: 1000),
          throwsA(isA<BathymetryFetchException>()),
        );
      },
    );

    test(
      'stitches all tiles the requested spanMeters bounding box touches',
      () async {
        // Straddles the LV95 easting=2685000 tile boundary while a wide
        // northing margin keeps it inside a single northing tile (1245), so
        // spanMeters=200 needs exactly two adjacent tiles east-west.
        const boundaryPoint = GeoPoint(47.354865314, 8.563694834);

        const tileAGrid = '''
ncols 2
nrows 2
xllcorner 2684000
yllcorner 1245000
cellsize 500
nodata_value -9999
400.0 400.0
400.0 400.0
''';
        const tileBGrid = '''
ncols 2
nrows 2
xllcorner 2685000
yllcorner 1245000
cellsize 500
nodata_value -9999
410.0 410.0
410.0 -9999
''';

        var itemCalls = 0;
        var downloadCalls = 0;
        final source = buildSource((req) async {
          if (req.url.path.endsWith('/items')) {
            itemCalls++;
            final href = itemCalls == 1
                ? 'https://example.org/tile_a.zip'
                : 'https://example.org/tile_b.zip';
            return http.Response(
              jsonEncode({
                'features': [
                  {
                    'bbox': _requestedBbox(req),
                    'assets': {
                      'grid': {'href': href},
                    },
                  },
                ],
              }),
              200,
            );
          }
          downloadCalls++;
          final body = req.url.path.endsWith('tile_a.zip')
              ? tileAGrid
              : tileBGrid;
          return http.Response.bytes(_zipOf('tile.asc', body), 200);
        });

        final grid = await source.fetch(boundaryPoint, spanMeters: 200);

        expect(itemCalls, 2);
        expect(downloadCalls, 2);
        expect(grid.rows, 2);
        expect(grid.cols, 4);

        // West tile (Z=400 -> depth 6.1) occupies the western columns, east
        // tile (Z=410 -> depth -3.9) the eastern ones: stitched side by
        // side, not overwritten or overlapping.
        expect(grid.depthAt(0, 0), closeTo(406.1 - 400.0, 1e-6));
        expect(grid.depthAt(1, 0), closeTo(406.1 - 400.0, 1e-6));
        expect(grid.depthAt(0, 2), closeTo(406.1 - 410.0, 1e-6));
        expect(grid.depthAt(1, 3), closeTo(406.1 - 410.0, 1e-6));
        // The east tile's nodata sentinel survives stitching as a gap.
        expect(grid.depthAt(0, 3), isNull);
      },
    );

    test('the query coordinate stays inside the stitched mosaic\'s rendered '
        'bounds, at realistic tile resolution and tile count', () async {
      // The 3D scene always places the dive site marker at (0,0) in a
      // frame centered on the exact query coordinate (see
      // SiteSeascapeGeometryService._sitePin / BathymetryTerrainBuilder.
      // enuBounds), so the terrain mesh built from a stitched mosaic must
      // actually enclose that coordinate -- otherwise the marker renders
      // outside the mesh it is supposed to sit on.
      const center = zurichseePoint;
      final centerLv95 = Lv95Transform.fromWgs84(
        center.latitude,
        center.longitude,
      );
      final baseTileE = (centerLv95.easting / 1000).floor();
      final baseTileN = (centerLv95.northing / 1000).floor();

      const cellsize = 2.0;
      const cellsPerTile = 500; // swissBATHY3D's real 1 km / 2 m tiling

      String tileGrid(int tileE, int tileN) {
        final row = List.filled(cellsPerTile, '400.0').join(' ');
        final buffer = StringBuffer()
          ..writeln('ncols $cellsPerTile')
          ..writeln('nrows $cellsPerTile')
          ..writeln('xllcorner ${tileE * 1000}')
          ..writeln('yllcorner ${tileN * 1000}')
          ..writeln('cellsize $cellsize')
          ..writeln('nodata_value -9999');
        for (var r = 0; r < cellsPerTile; r++) {
          buffer.writeln(row);
        }
        return buffer.toString();
      }

      // Deterministic fetch order: tileN outer, tileE inner (matches
      // SwissBathy3dSource.fetch's nested loop).
      final tileKeys = <String>[
        for (var tN = baseTileN - 1; tN <= baseTileN + 1; tN++)
          for (var tE = baseTileE - 1; tE <= baseTileE + 1; tE++) '${tE}_$tN',
      ];
      final tileBodies = {
        for (final key in tileKeys)
          key: tileGrid(
            int.parse(key.split('_')[0]),
            int.parse(key.split('_')[1]),
          ),
      };

      var itemSeq = 0;
      var downloadSeq = 0;
      final source = buildSource((req) async {
        if (req.url.path.endsWith('/items')) {
          final key = tileKeys[itemSeq++];
          return http.Response(
            jsonEncode({
              'features': [
                {
                  'bbox': _requestedBbox(req),
                  'assets': {
                    'grid': {'href': 'https://example.org/$key.zip'},
                  },
                },
              ],
            }),
            200,
          );
        }
        final key = tileKeys[downloadSeq++];
        return http.Response.bytes(_zipOf('tile.asc', tileBodies[key]!), 200);
      });

      final grid = await source.fetch(center, spanMeters: 2500);
      final box = BathymetryTerrainBuilder.enuBounds(grid, center);

      expect(box.minEast, lessThanOrEqualTo(0));
      expect(box.maxEast, greaterThanOrEqualTo(0));
      expect(box.minNorth, lessThanOrEqualTo(0));
      expect(box.maxNorth, greaterThanOrEqualTo(0));
    });

    test('a STAC server that ignores bbox filtering and always answers with an '
        'unrelated tile fails the fetch instead of silently returning a mesh '
        'that does not actually cover the query coordinate', () async {
      // Regression test for the real Bug 6 symptom: the rendered terrain
      // looked like genuine, plausible swissBATHY3D data, but the dive
      // site marker (placed at the exact query coordinate, per
      // BathymetryTerrainBuilder.enuBounds / SiteSeascapeGeometryService)
      // sat far outside it. That can only happen if fetch() returns a
      // grid whose real geographic footprint does not actually contain
      // the query coordinate -- which is exactly what happens if
      // SwissStacClient trusts the server's spatial filtering blindly and
      // the server (bug, unsupported bbox param, or a differently-shaped
      // items response than assumed -- never verified live, see
      // SwissStacClient's class doc) answers every tile lookup with the
      // same unrelated item regardless of the requested bbox.
      var itemCalls = 0;
      var downloadCalls = 0;
      final source = buildSource((req) async {
        if (req.url.path.endsWith('/items')) {
          itemCalls++;
          // A real item, but for a location nowhere near any of the 9x9
          // tiles this fetch actually asked about (its own declared bbox
          // sits far from every requested tile bbox).
          return http.Response(
            jsonEncode({
              'features': [
                {
                  'bbox': [8.9, 46.0, 8.91, 46.01],
                  'assets': {
                    'grid': {'href': 'https://example.org/unrelated.zip'},
                  },
                },
              ],
            }),
            200,
          );
        }
        downloadCalls++;
        return http.Response.bytes(_zipOf('tile.asc', gridBody), 200);
      });

      await expectLater(
        source.fetch(zurichseePoint, spanMeters: 2000),
        throwsA(isA<BathymetryFetchException>()),
      );
      // Every one of the 3x3 requested tiles queried STAC (and each was
      // correctly recognized as not actually answering that tile)...
      expect(itemCalls, 9);
      // ...so the mismatched asset was never downloaded and spliced into
      // the mosaic at all.
      expect(downloadCalls, 0);
    });

    test('a transient failure on one tile does not sink neighboring tiles that '
        'already succeeded', () async {
      // Same boundary point/span as the stitching test above: exactly two
      // tiles. Tile A's STAC items lookup succeeds; tile B's returns a
      // server error, simulating the kind of one-off network hiccup that
      // becomes likely once a single site view can span dozens of tiles.
      const boundaryPoint = GeoPoint(47.354865314, 8.563694834);
      const tileAGrid = '''
ncols 2
nrows 2
xllcorner 2684000
yllcorner 1245000
cellsize 500
nodata_value -9999
400.0 400.0
400.0 400.0
''';

      var itemCalls = 0;
      final source = buildSource((req) async {
        if (req.url.path.endsWith('/items')) {
          itemCalls++;
          if (itemCalls == 1) {
            return http.Response(
              jsonEncode({
                'features': [
                  {
                    'bbox': _requestedBbox(req),
                    'assets': {
                      'grid': {'href': 'https://example.org/tile_a.zip'},
                    },
                  },
                ],
              }),
              200,
            );
          }
          return http.Response('server error', 500);
        }
        return http.Response.bytes(_zipOf('tile.asc', tileAGrid), 200);
      });

      // Must not throw despite the second tile's 500: tile A's data is
      // still returned instead of the whole fetch failing.
      final grid = await source.fetch(boundaryPoint, spanMeters: 200);

      expect(itemCalls, 2);
      expect(grid.rows, 2);
      expect(grid.cols, 2);
      expect(grid.depthAt(0, 0), closeTo(406.1 - 400.0, 1e-6));

      // The failed tile was never cached as a definitive answer, so a
      // later retry (e.g. once the network recovers) queries it again
      // rather than being permanently stuck as "no data".
      final again = await source.fetch(boundaryPoint, spanMeters: 200);
      expect(itemCalls, 3);
      expect(again.depthAt(0, 0), closeTo(406.1 - 400.0, 1e-6));
    });

    test('throws when every tile in the span fails transiently, so the '
        'resolver falls through instead of caching a false negative', () async {
      const boundaryPoint = GeoPoint(47.354865314, 8.563694834);
      var itemCalls = 0;
      final source = buildSource((req) async {
        itemCalls++;
        return http.Response('server error', 500);
      });

      await expectLater(
        source.fetch(boundaryPoint, spanMeters: 200),
        throwsA(isA<BathymetryFetchException>()),
      );
      expect(itemCalls, 2);
    });

    test('a missing tile inside the span is a gap, not a crash, when at least '
        'one neighboring tile has data', () async {
      // Same boundary point/span as above, but the east tile has no STAC
      // item at all (empty feature list) — a genuine coverage gap.
      const boundaryPoint = GeoPoint(47.354865314, 8.563694834);
      const tileAGrid = '''
ncols 2
nrows 2
xllcorner 2684000
yllcorner 1245000
cellsize 500
nodata_value -9999
400.0 400.0
400.0 400.0
''';

      var itemCalls = 0;
      final source = buildSource((req) async {
        if (req.url.path.endsWith('/items')) {
          itemCalls++;
          if (itemCalls == 1) {
            return http.Response(
              jsonEncode({
                'features': [
                  {
                    'bbox': _requestedBbox(req),
                    'assets': {
                      'grid': {'href': 'https://example.org/tile_a.zip'},
                    },
                  },
                ],
              }),
              200,
            );
          }
          return http.Response(jsonEncode({'features': []}), 200);
        }
        return http.Response.bytes(_zipOf('tile.asc', tileAGrid), 200);
      });

      final grid = await source.fetch(boundaryPoint, spanMeters: 200);

      expect(itemCalls, 2);
      expect(grid.rows, 2);
      expect(grid.cols, 2);
      expect(grid.depthAt(0, 0), closeTo(406.1 - 400.0, 1e-6));
    });
  });

  group('SwissBathy3dSource periodic freshness check', () {
    Future<void> backdateCheckedAt(GeoPoint point, DateTime checkedAt) async {
      final lv95 = Lv95Transform.fromWgs84(point.latitude, point.longitude);
      final tileKey = SwissBathy3dSource.tileKeyFor(lv95);
      await (db.update(
        db.swissBathyTileCache,
      )..where((t) => t.tileKey.equals(tileKey))).write(
        SwissBathyTileCacheCompanion(
          checkedAt: Value(checkedAt.millisecondsSinceEpoch),
        ),
      );
    }

    test('a stale cached tile triggers exactly one light metadata check and '
        'no download when the source version is unchanged', () async {
      var itemCalls = 0;
      var downloadCalls = 0;
      final source = buildSource((req) async {
        if (req.url.path.endsWith('/items')) {
          itemCalls++;
          return http.Response(
            jsonEncode({
              'features': [
                {
                  'bbox': _requestedBbox(req),
                  'properties': {'datetime': '2023-01-01T00:00:00Z'},
                  'assets': {
                    'grid': {'href': 'https://example.org/tile_grid.zip'},
                  },
                },
              ],
            }),
            200,
          );
        }
        downloadCalls++;
        return http.Response.bytes(_zipOf('tile.asc', gridBody), 200);
      });

      final first = await source.fetch(zurichseePoint, spanMeters: 100);
      expect(itemCalls, 1);
      expect(downloadCalls, 1);

      await backdateCheckedAt(
        zurichseePoint,
        DateTime.now().subtract(const Duration(days: 31)),
      );

      final second = await source.fetch(zurichseePoint, spanMeters: 100);
      expect(itemCalls, 2); // exactly one extra light metadata lookup
      expect(downloadCalls, 1); // unchanged version: no re-download
      expect(second.depthAt(0, 0), first.depthAt(0, 0));
    });

    test(
      'a stale cached tile is re-downloaded when the source version changed',
      () async {
        const updatedGrid = '''
ncols 2
nrows 2
xllcorner 2685000
yllcorner 1245000
cellsize 500
nodata_value -9999
500.0 500.0
500.0 500.0
''';

        var itemCalls = 0;
        var downloadCalls = 0;
        final source = buildSource((req) async {
          if (req.url.path.endsWith('/items')) {
            itemCalls++;
            final datetime = itemCalls == 1
                ? '2023-01-01T00:00:00Z'
                : '2024-06-01T00:00:00Z';
            return http.Response(
              jsonEncode({
                'features': [
                  {
                    'bbox': _requestedBbox(req),
                    'properties': {'datetime': datetime},
                    'assets': {
                      'grid': {'href': 'https://example.org/tile_grid.zip'},
                    },
                  },
                ],
              }),
              200,
            );
          }
          downloadCalls++;
          final body = downloadCalls == 1 ? gridBody : updatedGrid;
          return http.Response.bytes(_zipOf('tile.asc', body), 200);
        });

        final first = await source.fetch(zurichseePoint, spanMeters: 100);
        expect(downloadCalls, 1);

        await backdateCheckedAt(
          zurichseePoint,
          DateTime.now().subtract(const Duration(days: 31)),
        );

        final second = await source.fetch(zurichseePoint, spanMeters: 100);
        expect(itemCalls, 2);
        expect(downloadCalls, 2); // changed version: re-downloaded
        expect(second.depthAt(0, 0), isNot(first.depthAt(0, 0)));

        // The refreshed version is now cached: a third fetch right after
        // does not check again (checkedAt was just bumped).
        final third = await source.fetch(zurichseePoint, spanMeters: 100);
        expect(itemCalls, 2);
        expect(third.depthAt(0, 0), second.depthAt(0, 0));
      },
    );

    test(
      'a failed metadata check on a stale tile serves the cached grid '
      'without throwing, offline-safe like the fetch-failure fallback',
      () async {
        var itemCalls = 0;
        var downloadCalls = 0;
        final source = buildSource((req) async {
          if (req.url.path.endsWith('/items')) {
            itemCalls++;
            if (itemCalls == 1) {
              return http.Response(
                jsonEncode({
                  'features': [
                    {
                      'bbox': _requestedBbox(req),
                      'properties': {'datetime': '2023-01-01T00:00:00Z'},
                      'assets': {
                        'grid': {'href': 'https://example.org/tile_grid.zip'},
                      },
                    },
                  ],
                }),
                200,
              );
            }
            return http.Response('server error', 500);
          }
          downloadCalls++;
          return http.Response.bytes(_zipOf('tile.asc', gridBody), 200);
        });

        final first = await source.fetch(zurichseePoint, spanMeters: 100);

        await backdateCheckedAt(
          zurichseePoint,
          DateTime.now().subtract(const Duration(days: 31)),
        );

        final second = await source.fetch(zurichseePoint, spanMeters: 100);
        expect(itemCalls, 2);
        expect(downloadCalls, 1); // the failed check never re-downloads
        expect(second.depthAt(0, 0), first.depthAt(0, 0));
      },
    );

    test('a tile cached before the freshness fields existed (checkedAt null) '
        'is treated as due for a check immediately', () async {
      var itemCalls = 0;
      var downloadCalls = 0;
      final source = buildSource((req) async {
        if (req.url.path.endsWith('/items')) {
          itemCalls++;
          return http.Response(
            jsonEncode({
              'features': [
                {
                  'bbox': _requestedBbox(req),
                  'properties': {'datetime': '2023-01-01T00:00:00Z'},
                  'assets': {
                    'grid': {'href': 'https://example.org/tile_grid.zip'},
                  },
                },
              ],
            }),
            200,
          );
        }
        downloadCalls++;
        return http.Response.bytes(_zipOf('tile.asc', gridBody), 200);
      });

      await source.fetch(zurichseePoint, spanMeters: 100);
      expect(itemCalls, 1);
      expect(downloadCalls, 1);

      // Simulate a row written before checkedAt/sourceDatetime existed.
      final lv95 = Lv95Transform.fromWgs84(
        zurichseePoint.latitude,
        zurichseePoint.longitude,
      );
      final tileKey = SwissBathy3dSource.tileKeyFor(lv95);
      await (db.update(
        db.swissBathyTileCache,
      )..where((t) => t.tileKey.equals(tileKey))).write(
        const SwissBathyTileCacheCompanion(
          checkedAt: Value(null),
          sourceDatetime: Value(null),
        ),
      );

      final grid = await source.fetch(zurichseePoint, spanMeters: 100);
      expect(itemCalls, 2); // checked immediately since checkedAt is null
      // A null sourceDatetime (pre-v15 row) never equals a real version
      // token, so this one-off check re-downloads once to establish a
      // baseline -- after which sourceDatetime is populated and later
      // checks behave like the "unchanged version" case above.
      expect(downloadCalls, 2);
      expect(grid.rows, 4);
    });
  });

  group('SwissBathy3dSource.refreshAllCachedTiles (manual reload)', () {
    test('no cached tiles: nothing to check, no HTTP calls', () async {
      final source = buildSource((_) async => http.Response('', 404));
      final summary = await source.refreshAllCachedTiles();
      expect(summary.total, 0);
      expect(summary.updated, 0);
      expect(summary.upToDate, 0);
      expect(summary.failed, 0);
    });

    test('revalidates a freshly cached tile immediately, without waiting for '
        'staleCheckInterval, and finds it unchanged', () async {
      var itemCalls = 0;
      var downloadCalls = 0;
      final source = buildSource((req) async {
        if (req.url.path.endsWith('/items')) {
          itemCalls++;
          return http.Response(
            jsonEncode({
              'features': [
                {
                  'bbox': _requestedBbox(req),
                  'properties': {'datetime': '2023-01-01T00:00:00Z'},
                  'assets': {
                    'grid': {'href': 'https://example.org/tile_grid.zip'},
                  },
                },
              ],
            }),
            200,
          );
        }
        downloadCalls++;
        return http.Response.bytes(_zipOf('tile.asc', gridBody), 200);
      });

      await source.fetch(zurichseePoint, spanMeters: 100);
      expect(itemCalls, 1);
      expect(downloadCalls, 1);

      // No backdating of checkedAt here: the manual action must revalidate
      // right away instead of waiting for staleCheckInterval to elapse.
      final summary = await source.refreshAllCachedTiles();
      expect(itemCalls, 2); // exactly one extra light metadata lookup
      expect(downloadCalls, 1); // unchanged version: no re-download
      expect(summary.total, 1);
      expect(summary.upToDate, 1);
      expect(summary.updated, 0);
      expect(summary.failed, 0);
    });

    test('re-downloads a cached tile whose version actually changed', () async {
      const updatedGrid = '''
ncols 2
nrows 2
xllcorner 2685000
yllcorner 1245000
cellsize 500
nodata_value -9999
500.0 500.0
500.0 500.0
''';
      var itemCalls = 0;
      var downloadCalls = 0;
      final source = buildSource((req) async {
        if (req.url.path.endsWith('/items')) {
          itemCalls++;
          final datetime = itemCalls == 1
              ? '2023-01-01T00:00:00Z'
              : '2024-06-01T00:00:00Z';
          return http.Response(
            jsonEncode({
              'features': [
                {
                  'bbox': _requestedBbox(req),
                  'properties': {'datetime': datetime},
                  'assets': {
                    'grid': {'href': 'https://example.org/tile_grid.zip'},
                  },
                },
              ],
            }),
            200,
          );
        }
        downloadCalls++;
        final body = downloadCalls == 1 ? gridBody : updatedGrid;
        return http.Response.bytes(_zipOf('tile.asc', body), 200);
      });

      final first = await source.fetch(zurichseePoint, spanMeters: 100);

      final summary = await source.refreshAllCachedTiles();
      expect(itemCalls, 2);
      expect(downloadCalls, 2); // changed version: re-downloaded
      expect(summary.updated, 1);
      expect(summary.upToDate, 0);
      expect(summary.failed, 0);

      final again = await source.fetch(zurichseePoint, spanMeters: 100);
      expect(again.depthAt(0, 0), isNot(first.depthAt(0, 0)));
    });

    test('a failed metadata check counts as failed and keeps the cached grid '
        'unchanged, offline-safe like the periodic check', () async {
      var itemCalls = 0;
      var downloadCalls = 0;
      final source = buildSource((req) async {
        if (req.url.path.endsWith('/items')) {
          itemCalls++;
          if (itemCalls == 1) {
            return http.Response(
              jsonEncode({
                'features': [
                  {
                    'bbox': _requestedBbox(req),
                    'properties': {'datetime': '2023-01-01T00:00:00Z'},
                    'assets': {
                      'grid': {'href': 'https://example.org/tile_grid.zip'},
                    },
                  },
                ],
              }),
              200,
            );
          }
          return http.Response('server error', 500);
        }
        downloadCalls++;
        return http.Response.bytes(_zipOf('tile.asc', gridBody), 200);
      });

      final first = await source.fetch(zurichseePoint, spanMeters: 100);

      final summary = await source.refreshAllCachedTiles();
      expect(summary.failed, 1);
      expect(summary.updated, 0);
      expect(summary.upToDate, 0);
      expect(downloadCalls, 1); // no re-download attempted

      final again = await source.fetch(zurichseePoint, spanMeters: 100);
      expect(again.depthAt(0, 0), first.depthAt(0, 0));
    });

    test(
      'sweeps every cached tile independently and tallies mixed outcomes',
      () async {
        // Distinct lake, well outside zurichseePoint's tile (and away from
        // its own tile's boundary, so spanMeters: 100 stays single-tile).
        const bodenseePoint = GeoPoint(47.55, 9.20);

        var itemCalls = 0;
        var downloadCalls = 0;
        final source = buildSource((req) async {
          if (req.url.path.endsWith('/items')) {
            itemCalls++;
            // Calls 1-2 are the initial fetches for the two tiles; call 3
            // (whichever tile the sweep checks first) finds no change,
            // call 4 (the other tile) fails transiently.
            if (itemCalls <= 3) {
              return http.Response(
                jsonEncode({
                  'features': [
                    {
                      'bbox': _requestedBbox(req),
                      'properties': {'datetime': '2023-01-01T00:00:00Z'},
                      'assets': {
                        'grid': {'href': 'https://example.org/tile_grid.zip'},
                      },
                    },
                  ],
                }),
                200,
              );
            }
            return http.Response('server error', 500);
          }
          downloadCalls++;
          return http.Response.bytes(_zipOf('tile.asc', gridBody), 200);
        });

        await source.fetch(zurichseePoint, spanMeters: 100);
        await source.fetch(bodenseePoint, spanMeters: 100);
        expect(itemCalls, 2);
        expect(downloadCalls, 2);

        final summary = await source.refreshAllCachedTiles();
        expect(summary.total, 2);
        expect(summary.upToDate, 1);
        expect(summary.failed, 1);
        expect(summary.updated, 0);
      },
    );

    test('a cached "no tile here" negative is not part of the sweep, since '
        'there is no grid to revalidate', () async {
      var itemCalls = 0;
      final source = buildSource((req) async {
        itemCalls++;
        return http.Response(jsonEncode({'features': []}), 200);
      });

      await expectLater(
        source.fetch(zurichseePoint, spanMeters: 100),
        throwsA(isA<BathymetryFetchException>()),
      );
      expect(itemCalls, 1);

      final summary = await source.refreshAllCachedTiles();
      expect(summary.total, 0);
      expect(itemCalls, 1); // no extra lookup for the cached negative
    });
  });

  group('SwissBathy3dSource in the resolver chain', () {
    // Regression test for a bug observed after the swissBATHY3D integration:
    // a land coordinate outside every known lake stopped loading a 3D model
    // at all. Root cause turned out to be the multi-tile stitching bug (a
    // separate fix) rather than the fallback logic itself, but nothing
    // previously exercised the full resolver + real source combination for
    // this case — this locks that path in.
    test('a land coordinate outside every known lake falls through to the '
        'next resolver tier and still yields a result', () async {
      var httpCalls = 0;
      final swissSource = buildSource((_) async {
        httpCalls++;
        return http.Response('', 404);
      });
      final fallback = _FakeFallbackSource();

      final resolution = await BathymetryResolver(
        sources: [swissSource, fallback],
      ).resolve(alpsPoint);

      // covers() already excludes it; the tier makes no network call.
      expect(httpCalls, 0);
      expect(fallback.fetchCount, 1);
      expect(resolution.grid?.sourceId, 'fallback');
      expect(resolution.definitive, isTrue);
    });
  });
}

class _FakeFallbackSource implements BathymetrySource {
  int fetchCount = 0;

  @override
  String get id => 'fallback';

  @override
  bool get global => true;

  @override
  bool covers(GeoPoint center) => true;

  @override
  Future<BathymetryGrid> fetch(
    GeoPoint center, {
    required double spanMeters,
  }) async {
    fetchCount++;
    return BathymetryGrid(
      originLat: center.latitude,
      originLon: center.longitude,
      cellSizeLatDeg: 0.004,
      cellSizeLonDeg: 0.004,
      rows: 1,
      cols: 10,
      depthsMeters: [for (var i = 0; i < 10; i++) 50.0],
      sourceId: 'fallback',
      resolutionMeters: 100,
      fetchedAt: DateTime.utc(2026, 7, 28),
    );
  }
}
