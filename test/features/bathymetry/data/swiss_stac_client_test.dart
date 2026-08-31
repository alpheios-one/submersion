import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:submersion/features/bathymetry/data/sources/swiss_stac_client.dart';

void main() {
  const bbox = [8.54, 47.24, 8.55, 47.25];

  group('SwissStacClient.findAsset', () {
    test('picks an ESRI ASCII grid asset over an XYZ one', () async {
      late Uri requested;
      final client = SwissStacClient(
        client: MockClient((req) async {
          requested = req.url;
          return http.Response(
            jsonEncode({
              'features': [
                {
                  'assets': {
                    'xyz': {
                      'href': 'https://example.org/tile_2685_1240.xyz.zip',
                    },
                    'grid': {
                      'href': 'https://example.org/tile_2685_1240_grid.zip',
                    },
                  },
                },
              ],
            }),
            200,
          );
        }),
      );
      final asset = await client.findAsset(
        collectionId: 'ch.swisstopo.swissbathy3d',
        bbox: bbox,
      );
      expect(asset, isNotNull);
      expect(asset!.format, 'esri-ascii');
      expect(asset.href, contains('_grid.zip'));
      expect(requested.path, contains('ch.swisstopo.swissbathy3d/items'));
      expect(requested.queryParameters['bbox'], bbox.join(','));
    });

    test('carries the item datetime as the asset version token', () async {
      final client = SwissStacClient(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'features': [
                {
                  'properties': {'datetime': '2023-05-01T00:00:00Z'},
                  'assets': {
                    'grid': {
                      'href': 'https://example.org/tile_2685_1240_grid.zip',
                    },
                  },
                },
              ],
            }),
            200,
          ),
        ),
      );
      final asset = await client.findAsset(
        collectionId: 'ch.swisstopo.swissbathy3d',
        bbox: bbox,
      );
      expect(asset!.datetime, '2023-05-01T00:00:00Z');
    });

    test(
      'falls back to "updated" then "created" when datetime is absent',
      () async {
        final client = SwissStacClient(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'features': [
                  {
                    'properties': {'created': '2021-01-01T00:00:00Z'},
                    'assets': {
                      'grid': {'href': 'https://example.org/tile_grid.zip'},
                    },
                  },
                ],
              }),
              200,
            ),
          ),
        );
        final asset = await client.findAsset(
          collectionId: 'ch.swisstopo.swissbathy3d',
          bbox: bbox,
        );
        expect(asset!.datetime, '2021-01-01T00:00:00Z');
      },
    );

    test('datetime is null when the item has no properties', () async {
      final client = SwissStacClient(
        client: MockClient(
          (_) async => http.Response(
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
          ),
        ),
      );
      final asset = await client.findAsset(
        collectionId: 'ch.swisstopo.swissbathy3d',
        bbox: bbox,
      );
      expect(asset!.datetime, isNull);
    });

    test('falls back to any zip asset when none looks like a grid', () async {
      final client = SwissStacClient(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'features': [
                {
                  'assets': {
                    'data': {'href': 'https://example.org/tile.zip'},
                  },
                },
              ],
            }),
            200,
          ),
        ),
      );
      final asset = await client.findAsset(
        collectionId: 'ch.swisstopo.swissbathy3d',
        bbox: bbox,
      );
      expect(asset, isNotNull);
      expect(asset!.format, 'unknown');
    });

    test('returns null when the collection has no matching item', () async {
      final client = SwissStacClient(
        client: MockClient(
          (_) async => http.Response(jsonEncode({'features': []}), 200),
        ),
      );
      final asset = await client.findAsset(
        collectionId: 'ch.swisstopo.swissbathy3d',
        bbox: bbox,
      );
      expect(asset, isNull);
    });

    test('throws SwissStacCollectionNotFoundException on 404', () async {
      final client = SwissStacClient(
        client: MockClient((_) async => http.Response('not found', 404)),
      );
      expect(
        () => client.findAsset(
          collectionId: 'ch.swisstopo.swissbathy3d_wrong',
          bbox: bbox,
        ),
        throwsA(isA<SwissStacCollectionNotFoundException>()),
      );
    });

    test('throws SwissStacException on a server error', () async {
      final client = SwissStacClient(
        client: MockClient((_) async => http.Response('oops', 500)),
      );
      expect(
        () => client.findAsset(
          collectionId: 'ch.swisstopo.swissbathy3d',
          bbox: bbox,
        ),
        throwsA(isA<SwissStacException>()),
      );
    });

    test('throws SwissStacException on an unparseable body', () async {
      final client = SwissStacClient(
        client: MockClient((_) async => http.Response('<html></html>', 200)),
      );
      expect(
        () => client.findAsset(
          collectionId: 'ch.swisstopo.swissbathy3d',
          bbox: bbox,
        ),
        throwsA(isA<SwissStacException>()),
      );
    });
  });

  group('SwissStacClient.downloadBytes', () {
    test('returns the response bytes on 200', () async {
      final client = SwissStacClient(
        client: MockClient((_) async => http.Response.bytes([1, 2, 3], 200)),
      );
      final bytes = await client.downloadBytes('https://example.org/a.zip');
      expect(bytes, [1, 2, 3]);
    });

    test('throws SwissStacException on a non-200 status', () async {
      final client = SwissStacClient(
        client: MockClient((_) async => http.Response('nope', 404)),
      );
      expect(
        () => client.downloadBytes('https://example.org/a.zip'),
        throwsA(isA<SwissStacException>()),
      );
    });
  });
}
