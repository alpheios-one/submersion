import 'dart:convert';
import 'dart:io';

const String inaturalistUserAgent = 'Submersion/1.0 (https://submersion.app)';

/// Resolves a scientific name to its iNaturalist taxon with every name
/// attached (`all_names=true`). One request per species; the caller paces.
class InaturalistNamesClient {
  InaturalistNamesClient({HttpClient? client})
    : _client = client ?? HttpClient();

  final HttpClient _client;

  /// The taxon whose `name` equals [scientificName] (or the taxon [taxonId]
  /// when given), or null when iNaturalist has no such species.
  Future<Map<String, dynamic>?> taxonByScientificName(
    String scientificName, {
    int? taxonId,
  }) async {
    final uri = taxonId != null
        ? Uri.parse(
            'https://api.inaturalist.org/v1/taxa/$taxonId?all_names=true',
          )
        : Uri.parse(
            'https://api.inaturalist.org/v1/taxa'
            '?q=${Uri.encodeQueryComponent(scientificName)}'
            '&rank=species&all_names=true&per_page=5',
          );
    for (var attempt = 1; attempt <= 3; attempt++) {
      final request = await _client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, inaturalistUserAgent);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode == 200) {
        final results =
            ((jsonDecode(body) as Map<String, dynamic>)['results'] as List)
                .cast<Map<String, dynamic>>();
        for (final r in results) {
          if (taxonId != null || r['name'] == scientificName) return r;
        }
        return null;
      }
      await Future<void>.delayed(Duration(seconds: 2 * attempt));
    }
    throw HttpException('iNaturalist failed for $scientificName');
  }

  void close() => _client.close();
}
