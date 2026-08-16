import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart';
// `geocoding` declares its own app-facing `Geocoding`, which shadows the
// platform-interface class of the same name that fakes must extend.
import 'package:geocoding_platform_interface/geocoding_platform_interface.dart'
    as gpi;
import 'package:submersion/core/services/location_service.dart';

/// One canned HTTP exchange plus a record of what the service actually sent.
///
/// The geocoding paths talk to Nominatim through `dart:io HttpClient`, so the
/// only seam that does not require a real socket is [HttpOverrides]. Every
/// request the service makes is captured here so the tests can assert on the
/// English pin (#214) that lives in the URI *and* in the request headers.
class _FakeNominatim {
  _FakeNominatim({this.statusCode = 200, this.body = '{}'});

  final int statusCode;
  final String body;

  final List<Uri> requestedUris = <Uri>[];
  final List<Map<String, String>> requestHeaders = <Map<String, String>>[];
  int clientCloseCount = 0;

  Uri get lastUri => requestedUris.last;
  Map<String, String> get lastHeaders => requestHeaders.last;

  /// Run [body] with every `HttpClient` replaced by this fake server.
  Future<T> run<T>(Future<T> Function() action) =>
      HttpOverrides.runZoned<Future<T>>(
        action,
        createHttpClient: (SecurityContext? _) => _FakeHttpClient(this),
      );
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this._server);

  final _FakeNominatim _server;

  @override
  String? userAgent;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    _server.requestedUris.add(url);
    return _FakeHttpClientRequest(url, _server);
  }

  @override
  void close({bool force = false}) => _server.clientCloseCount++;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpClientRequest implements HttpClientRequest {
  _FakeHttpClientRequest(this.uri, this._server);

  final _FakeNominatim _server;

  @override
  final Uri uri;

  @override
  final HttpHeaders headers = _FakeHttpHeaders();

  @override
  Future<HttpClientResponse> close() async {
    _server.requestHeaders.add((headers as _FakeHttpHeaders).values);
    return _FakeHttpClientResponse(_server.statusCode, _server.body);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpHeaders implements HttpHeaders {
  final Map<String, String> values = <String, String>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = '$value';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeHttpClientResponse(this.statusCode, this._body);

  @override
  final int statusCode;

  final String _body;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.value(utf8.encode(_body)).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  final service = LocationService.instance;

  group('Nominatim URIs pin English results (#214)', () {
    test('reverse geocode URI carries accept-language=en', () {
      final uri = LocationService.buildReverseGeocodeUri(36.0, -5.6);
      expect(
        uri.queryParameters['accept-language'],
        'en',
        reason:
            'without a pinned language Nominatim answers in the request '
            'locale, splitting statistics into Spain/Spanien/España rows',
      );
      expect(uri.queryParameters['lat'], '36.0');
      expect(uri.queryParameters['lon'], '-5.6');
    });

    test('forward geocode URI carries accept-language=en', () {
      final uri = LocationService.buildForwardGeocodeUri('Blue Hole');
      expect(uri.queryParameters['accept-language'], 'en');
      expect(uri.queryParameters['q'], 'Blue Hole');
    });
  });

  group('reverseGeocode web fallback', () {
    test(
      'parses country, region and locality from a Nominatim response',
      () async {
        final server = _FakeNominatim(
          body: jsonEncode(<String, dynamic>{
            'address': <String, dynamic>{
              'country': 'Spain',
              'state': 'Andalusia',
              'city': 'Tarifa',
            },
          }),
        );

        final result = await server.run(
          () => service.reverseGeocode(36.0143, -5.6044),
        );

        expect(result.country, 'Spain');
        expect(result.region, 'Andalusia');
        expect(result.locality, 'Tarifa');
      },
    );

    test(
      'sends the English pin in both the URI and the request headers',
      () async {
        final server = _FakeNominatim(
          body: jsonEncode(<String, dynamic>{
            'address': <String, dynamic>{'country': 'Spain'},
          }),
        );

        await server.run(() => service.reverseGeocode(36.0143, -5.6044));

        expect(server.requestedUris, hasLength(1));
        expect(
          server.lastUri.queryParameters['accept-language'],
          'en',
          reason: 'the request itself must carry the pin, not just the builder',
        );
        expect(
          server.lastHeaders['accept-language'],
          'en',
          reason:
              'Nominatim honours the Accept-Language header over the query '
              'parameter, so both have to say en (#214)',
        );
        expect(
          server.lastUri.host,
          'nominatim.openstreetmap.org',
          reason: 'the fake must have intercepted the real endpoint',
        );
      },
    );

    test('falls back from state to province for the region', () async {
      final server = _FakeNominatim(
        body: jsonEncode(<String, dynamic>{
          'address': <String, dynamic>{
            'country': 'Canada',
            'province': 'Ontario',
            'town': 'Tobermory',
          },
        }),
      );

      final result = await server.run(
        () => service.reverseGeocode(45.2542, -81.6653),
      );

      expect(result.region, 'Ontario');
      expect(result.locality, 'Tobermory', reason: 'town backs up city');
    });

    test('falls back from province to region, and to village', () async {
      final server = _FakeNominatim(
        body: jsonEncode(<String, dynamic>{
          'address': <String, dynamic>{
            'country': 'Egypt',
            'region': 'Red Sea',
            'village': 'Dahab',
          },
        }),
      );

      final result = await server.run(
        () => service.reverseGeocode(28.5091, 34.5136),
      );

      expect(result.country, 'Egypt');
      expect(result.region, 'Red Sea');
      expect(result.locality, 'Dahab');
    });

    test(
      'returns empty fields when the payload has no address block',
      () async {
        final server = _FakeNominatim(
          body: jsonEncode(<String, dynamic>{'error': 'Unable to geocode'}),
        );

        final result = await server.run(() => service.reverseGeocode(0.0, 0.0));

        expect(result.country, isNull);
        expect(result.region, isNull);
        expect(result.locality, isNull);
      },
    );

    test('returns empty fields on a non-200 response', () async {
      final server = _FakeNominatim(
        statusCode: 503,
        body: 'Service Unavailable',
      );

      final result = await server.run(
        () => service.reverseGeocode(36.0143, -5.6044),
      );

      expect(result.country, isNull);
      expect(result.region, isNull);
      expect(result.locality, isNull);
    });

    test('swallows malformed JSON instead of throwing', () async {
      final server = _FakeNominatim(body: '<html>rate limited</html>');

      final result = await server.run(
        () => service.reverseGeocode(36.0143, -5.6044),
      );

      expect(result.country, isNull);
      expect(result.region, isNull);
      expect(result.locality, isNull);
    });

    test('closes the HttpClient even when the body fails to parse', () async {
      final server = _FakeNominatim(body: 'not json');

      await server.run(() => service.reverseGeocode(36.0143, -5.6044));

      expect(
        server.clientCloseCount,
        1,
        reason: 'the finally block must release the sockets on the error path',
      );
    });
  });

  group('forwardGeocode', () {
    test('returns the parsed coordinates and address details', () async {
      final server = _FakeNominatim(
        body: jsonEncode(<dynamic>[
          <String, dynamic>{
            'lat': '36.0143',
            'lon': '-5.6044',
            'address': <String, dynamic>{
              'country': 'Spain',
              'state': 'Andalusia',
              'city': 'Tarifa',
            },
          },
        ]),
      );

      final result = await server.run(() => service.forwardGeocode('Tarifa'));

      expect(result, isNotNull);
      expect(result!.latitude, closeTo(36.0143, 1e-9));
      expect(result.longitude, closeTo(-5.6044, 1e-9));
      expect(result.country, 'Spain');
      expect(result.region, 'Andalusia');
      expect(result.locality, 'Tarifa');
      expect(result.accuracy, isNull);
    });

    test(
      'sends the English pin in both the URI and the request headers',
      () async {
        final server = _FakeNominatim(
          body: jsonEncode(<dynamic>[
            <String, dynamic>{'lat': '36.0143', 'lon': '-5.6044'},
          ]),
        );

        await server.run(() => service.forwardGeocode('Blue Hole'));

        expect(server.requestedUris, hasLength(1));
        expect(server.lastUri.queryParameters['accept-language'], 'en');
        expect(server.lastUri.queryParameters['q'], 'Blue Hole');
        expect(server.lastHeaders['accept-language'], 'en');
      },
    );

    test('falls back from state to province, and from city to town', () async {
      final server = _FakeNominatim(
        body: jsonEncode(<dynamic>[
          <String, dynamic>{
            'lat': '45.2542',
            'lon': '-81.6653',
            'address': <String, dynamic>{
              'country': 'Canada',
              'province': 'Ontario',
              'town': 'Tobermory',
            },
          },
        ]),
      );

      final result = await server.run(
        () => service.forwardGeocode('Tobermory'),
      );

      expect(result!.region, 'Ontario');
      expect(result.locality, 'Tobermory');
    });

    test('falls back to region and village as the last options', () async {
      final server = _FakeNominatim(
        body: jsonEncode(<dynamic>[
          <String, dynamic>{
            'lat': '28.5091',
            'lon': '34.5136',
            'address': <String, dynamic>{
              'country': 'Egypt',
              'region': 'Red Sea',
              'village': 'Dahab',
            },
          },
        ]),
      );

      final result = await server.run(() => service.forwardGeocode('Dahab'));

      expect(result!.region, 'Red Sea');
      expect(result.locality, 'Dahab');
    });

    test(
      'returns coordinates with null details when address is absent',
      () async {
        final server = _FakeNominatim(
          body: jsonEncode(<dynamic>[
            <String, dynamic>{'lat': '12.5', 'lon': '-70.0'},
          ]),
        );

        final result = await server.run(() => service.forwardGeocode('Aruba'));

        expect(result!.latitude, closeTo(12.5, 1e-9));
        expect(result.longitude, closeTo(-70.0, 1e-9));
        expect(result.country, isNull);
        expect(result.region, isNull);
        expect(result.locality, isNull);
      },
    );

    test('returns null when Nominatim has no match', () async {
      final server = _FakeNominatim(body: '[]');

      final result = await server.run(
        () => service.forwardGeocode('Nowhere At All'),
      );

      expect(result, isNull);
    });

    test('returns null when the coordinates are not parseable', () async {
      final server = _FakeNominatim(
        body: jsonEncode(<dynamic>[
          <String, dynamic>{'lat': 'not-a-number', 'lon': '-5.6044'},
        ]),
      );

      final result = await server.run(() => service.forwardGeocode('Tarifa'));

      expect(result, isNull);
    });

    test('returns null on a non-200 response', () async {
      final server = _FakeNominatim(statusCode: 429, body: 'Too Many Requests');

      final result = await server.run(() => service.forwardGeocode('Tarifa'));

      expect(result, isNull);
      expect(
        server.clientCloseCount,
        1,
        reason: 'the client is closed even when the request is rejected',
      );
    });

    test('swallows malformed JSON instead of throwing', () async {
      final server = _FakeNominatim(body: '<html>rate limited</html>');

      final result = await server.run(() => service.forwardGeocode('Tarifa'));

      expect(result, isNull);
    });

    test(
      'short-circuits a blank address without hitting the network',
      () async {
        final server = _FakeNominatim(body: '[]');

        final result = await server.run(() => service.forwardGeocode('   '));

        expect(result, isNull);
        expect(
          server.requestedUris,
          isEmpty,
          reason: 'an empty query must never reach Nominatim',
        );
      },
    );
  });

  group('native geocoder locale (#214)', () {
    setUp(() {
      LocationService.debugForceNativeGeocoder = true;
    });

    tearDown(() {
      LocationService.debugForceNativeGeocoder = false;
    });

    test('asks the geocoder for English results', () async {
      final geocoding = _FakeGeocoding(
        placemarks: const [
          Placemark(
            country: 'Spain',
            administrativeArea: 'Andalusia',
            locality: 'Tarifa',
          ),
        ],
      );
      GeocodingPlatformFactory.instance = _FakeGeocodingFactory(geocoding);

      final result = await service.reverseGeocode(36.0143, -5.6044);

      expect(geocoding.locales, [const Locale('en')]);
      expect(result.country, 'Spain');
      expect(result.region, 'Andalusia');
      expect(result.locality, 'Tarifa');
    });

    test('every lookup carries the English locale', () async {
      final geocoding = _FakeGeocoding(
        placemarks: const [Placemark(country: 'Spain')],
      );
      GeocodingPlatformFactory.instance = _FakeGeocodingFactory(geocoding);

      await Future.wait([
        service.reverseGeocode(36.0, -5.6),
        service.reverseGeocode(37.0, -5.7),
        service.reverseGeocode(38.0, -5.8),
      ]);

      expect(
        geocoding.locales,
        [const Locale('en'), const Locale('en'), const Locale('en')],
        reason:
            'geocoding 5 resolves the locale per call, so unlike the old '
            'pin-once memo no later caller can inherit an unpinned geocoder',
      );
    });

    test('a failing native lookup falls back to the web geocoder', () async {
      final geocoding = _FakeGeocoding(
        placemarks: const [Placemark(country: 'Spain')],
        failOnce: true,
      );
      GeocodingPlatformFactory.instance = _FakeGeocodingFactory(geocoding);

      // The first attempt throws inside the native branch; the service falls
      // through to the web fallback rather than surfacing the failure.
      final server = _FakeNominatim(
        body: '{"address": {"country": "Fallback"}}',
      );
      final first = await server.run(() => service.reverseGeocode(36.0, -5.6));
      expect(
        first.country,
        'Fallback',
        reason: 'a native geocoder failure is non-fatal',
      );

      final second = await service.reverseGeocode(36.0, -5.6);

      expect(
        second.country,
        'Spain',
        reason: 'a later lookup retries the native geocoder',
      );
      expect(geocoding.locales, [const Locale('en'), const Locale('en')]);
    });
  });
}

/// Minimal [GeocodingPlatformFactory] handing out one fake [gpi.Geocoding].
class _FakeGeocodingFactory extends GeocodingPlatformFactory {
  _FakeGeocodingFactory(this.geocoding);

  final _FakeGeocoding geocoding;

  @override
  gpi.Geocoding createGeocoding(GeocodingCreationParams params) => geocoding;
}

/// Minimal geocoder that records the locale each lookup asked for.
class _FakeGeocoding extends gpi.Geocoding {
  _FakeGeocoding({required this.placemarks, this.failOnce = false})
    : super.implementation(const GeocodingCreationParams());

  final List<Placemark> placemarks;
  bool failOnce;

  final List<Locale?> locales = <Locale?>[];

  @override
  Future<List<Placemark>> placemarkFromCoordinates(
    double latitude,
    double longitude, {
    Locale? locale,
  }) async {
    locales.add(locale);
    if (failOnce) {
      failOnce = false;
      throw StateError('geocoder unavailable');
    }
    return placemarks;
  }
}
