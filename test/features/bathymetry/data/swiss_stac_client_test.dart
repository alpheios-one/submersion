import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:submersion/features/bathymetry/data/sources/swiss_stac_client.dart';

void main() {
  const bbox = [8.54, 47.24, 8.55, 47.25];
  const overlappingBbox = [8.535, 47.235, 8.555, 47.255];
  const decoyBbox = [9.5, 46.0, 9.51, 46.01];

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
                  'bbox': overlappingBbox,
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
                  'bbox': overlappingBbox,
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
                    'bbox': overlappingBbox,
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
                  'bbox': overlappingBbox,
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
                  'bbox': overlappingBbox,
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

    test('skips a feature whose own bbox does not overlap the request, even '
        'when the server returned it as the first result (a non-spatially- '
        'filtering or mis-paginating server must not splice an unrelated '
        'tile into the stitched mosaic)', () async {
      final client = SwissStacClient(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'features': [
                {
                  // Decoy: far from the requested tile. A server that
                  // ignores bbox (or paginates without filtering) could
                  // put this first regardless of what was asked for.
                  'bbox': decoyBbox,
                  'assets': {
                    'grid': {'href': 'https://example.org/decoy_grid.zip'},
                  },
                },
                {
                  'bbox': overlappingBbox,
                  'assets': {
                    'grid': {'href': 'https://example.org/correct_grid.zip'},
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
      expect(asset!.href, 'https://example.org/correct_grid.zip');
    });

    test('returns null when every candidate feature is a spatial decoy (no '
        'real match, rather than trusting an unrelated tile)', () async {
      final client = SwissStacClient(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'features': [
                {
                  'bbox': decoyBbox,
                  'assets': {
                    'grid': {'href': 'https://example.org/decoy_grid.zip'},
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
      expect(asset, isNull);
    });

    test('skips a feature with no bbox field at all (cannot be trusted, even '
        'though the STAC spec requires one for items with geometry)', () async {
      final client = SwissStacClient(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'features': [
                {
                  'assets': {
                    'grid': {'href': 'https://example.org/no_bbox.zip'},
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
      expect(asset, isNull);
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
