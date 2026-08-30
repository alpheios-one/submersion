import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// One selected STAC asset for a swissBATHY3D tile: a ZIP containing the
/// grid file.
class SwissBathyAsset {
  final String href;

  /// 'esri-ascii' when the href looks like an ESRI ASCII grid zip
  /// (preferred, per task design decision — smaller than XYZ), 'unknown'
  /// otherwise (still tried; the downloader falls back to whatever grid file
  /// it finds inside the zip).
  final String format;

  const SwissBathyAsset({required this.href, required this.format});
}

/// Thrown on any transient STAC failure (network error, timeout, non-200,
/// unparseable body). Callers must never cache this as a definitive answer.
class SwissStacException implements Exception {
  final String message;
  const SwissStacException(this.message);

  @override
  String toString() => 'SwissStacException: $message';
}

/// Thrown when a collection ID does not exist on the API (HTTP 404 on the
/// collection or its items endpoint) — distinct from [SwissStacException]
/// so callers can fall back to the next candidate ID instead of treating it
/// as a plain transient failure.
class SwissStacCollectionNotFoundException implements Exception {
  final String collectionId;
  const SwissStacCollectionNotFoundException(this.collectionId);

  @override
  String toString() =>
      'SwissStacCollectionNotFoundException: $collectionId not found';
}

/// Minimal client for the swisstopo STAC API (data.geo.admin.ch), scoped to
/// looking up the swissBATHY3D asset covering one bounding box.
///
/// [collectionIds] lists candidate collection IDs to try in order. The exact
/// ID was confirmed externally as `ch.swisstopo.swissbathy3d` (see PR
/// discussion), but a human with network access should verify this against
/// the live API before this path ships to users, per the task's design
/// decision to defend against an unexpected naming pattern.
class SwissStacClient {
  static const List<String> collectionIds = ['ch.swisstopo.swissbathy3d'];

  static const Duration _timeout = Duration(seconds: 15);

  final http.Client _client;
  final String baseUrl;

  SwissStacClient({
    http.Client? client,
    this.baseUrl = 'https://data.geo.admin.ch/api/stac/v1',
  }) : _client = client ?? http.Client();

  /// Finds the best asset among the items intersecting [bbox] (WGS84:
  /// [minLon, minLat, maxLon, maxLat]) in [collectionId].
  ///
  /// Returns null when the collection exists but no item/asset covers the
  /// box — a definitive "no tile here", safe to cache as a negative result.
  /// Throws [SwissStacCollectionNotFoundException] when [collectionId]
  /// itself does not exist, [SwissStacException] on any other transient
  /// failure.
  Future<SwissBathyAsset?> findAsset({
    required String collectionId,
    required List<double> bbox,
  }) async {
    final url = Uri.parse('$baseUrl/collections/$collectionId/items').replace(
      queryParameters: {
        'bbox': bbox.map((v) => v.toString()).join(','),
        'limit': '10',
      },
    );
    final http.Response resp;
    try {
      resp = await _client.get(url).timeout(_timeout);
    } catch (e) {
      throw SwissStacException('STAC items request failed: $e');
    }
    if (resp.statusCode == 404) {
      throw SwissStacCollectionNotFoundException(collectionId);
    }
    if (resp.statusCode != 200) {
      throw SwissStacException('STAC items HTTP ${resp.statusCode}');
    }
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (e) {
      throw SwissStacException('STAC items response not JSON: $e');
    }
    final features = body['features'] as List<dynamic>? ?? const [];
    for (final feature in features) {
      final assets =
          (feature as Map<String, dynamic>)['assets'] as Map<String, dynamic>?;
      if (assets == null) continue;
      final picked = _pickAsset(assets);
      if (picked != null) return picked;
    }
    return null;
  }

  static SwissBathyAsset? _pickAsset(Map<String, dynamic> assets) {
    SwissBathyAsset? bestGrid;
    SwissBathyAsset? anyZip;
    for (final asset in assets.values) {
      final href = (asset as Map<String, dynamic>?)?['href'] as String?;
      if (href == null) continue;
      final lower = href.toLowerCase();
      if (!lower.endsWith('.zip')) continue;
      final looksLikeGrid = lower.contains('grid') || lower.contains('asc');
      final looksLikeXyz = lower.contains('xyz');
      if (looksLikeGrid && !looksLikeXyz) {
        bestGrid ??= SwissBathyAsset(href: href, format: 'esri-ascii');
      }
      anyZip ??= SwissBathyAsset(href: href, format: 'unknown');
    }
    return bestGrid ?? anyZip;
  }

  /// Downloads the asset ZIP at [href].
  Future<Uint8List> downloadBytes(String href) async {
    final http.Response resp;
    try {
      resp = await _client.get(Uri.parse(href)).timeout(_timeout);
    } catch (e) {
      throw SwissStacException('Asset download failed: $e');
    }
    if (resp.statusCode != 200) {
      throw SwissStacException('Asset download HTTP ${resp.statusCode}');
    }
    return resp.bodyBytes;
  }
}
