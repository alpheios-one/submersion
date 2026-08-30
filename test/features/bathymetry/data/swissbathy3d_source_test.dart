import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:submersion/core/database/local_cache_database.dart';
import 'package:submersion/features/bathymetry/data/sources/swiss_bathy_tile_cache_repository.dart';
import 'package:submersion/features/bathymetry/data/sources/swiss_stac_client.dart';
import 'package:submersion/features/bathymetry/data/sources/swissbathy3d_source.dart';
import 'package:submersion/features/bathymetry/domain/bathymetry_source.dart';
import 'package:submersion/features/dive_sites/domain/entities/dive_site.dart';

Uint8List _zipOf(String entryName, String content) {
  final archive = Archive();
  final bytes = utf8.encode(content);
  archive.addFile(ArchiveFile(entryName, bytes.length, bytes));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

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

        final grid = await source.fetch(zurichseePoint, spanMeters: 1000);
        expect(grid.sourceId, 'swissbathy3d');
        expect(grid.rows, 4);
        expect(itemCalls, 1);
        expect(downloadCalls, 1);

        // Second fetch of a coordinate in the same tile must hit neither
        // the STAC API nor the download endpoint again (tile-level cache).
        final again = await source.fetch(zurichseePoint, spanMeters: 1000);
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
          source.fetch(zurichseePoint, spanMeters: 1000),
          throwsA(isA<BathymetryFetchException>()),
        );
        expect(itemCalls, 1);

        await expectLater(
          source.fetch(zurichseePoint, spanMeters: 1000),
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
  });
}
