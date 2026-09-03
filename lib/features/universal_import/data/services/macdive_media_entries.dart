import 'package:submersion/features/universal_import/data/services/macdive_raw_types.dart';
import 'package:submersion/features/universal_import/data/services/macdive_xml_models.dart';

/// Builds the `ImportEntityType.media` entries for a MacDive logbook.
///
/// Both MacDive formats feed the same import photo pipeline the Subsurface
/// parser uses, so the entry shape is that parser's contract: `filename`
/// is the path exactly as the source recorded it (resolved later against a
/// folder the user picks in the wizard's Photos step), `_diveIndex` is the
/// position of the owning dive in the payload's dives list, and the
/// `offsetSeconds` / `latitude` / `longitude` slots are present but null
/// because MacDive records neither a capture offset nor photo coordinates.
/// `caption` is MacDive's own addition to that contract.
Map<String, dynamic> macDiveMediaEntry({
  required String filename,
  required int diveIndex,
  String? caption,
}) {
  return {
    'filename': filename,
    'caption': caption,
    'offsetSeconds': null,
    'latitude': null,
    'longitude': null,
    '_diveIndex': diveIndex,
  };
}

/// Media entries for a SQLite logbook, ordered by dive and then by MacDive's
/// display position so the review list reads the way MacDive showed it.
///
/// `ZPATH` is preferred over `ZORIGINALPATH`: it names the copy MacDive
/// actually displays (and may have rotated or edited), and it is populated
/// for every row where the original path is not. A row whose dive is
/// missing from [dives], or that carries no path at all, is dropped.
List<Map<String, dynamic>> macDiveMediaEntriesFromImages({
  required List<MacDiveRawDive> dives,
  required List<MacDiveRawDiveImage> images,
}) {
  if (images.isEmpty) return const [];
  final diveIndexByPk = <int, int>{
    for (var i = 0; i < dives.length; i++) dives[i].pk: i,
  };

  // The primary key is carried so the sort has a tiebreaker: MacDive
  // leaves ZPOSITION null for nearly every row, and Dart's sort is only
  // stable up to 32 elements, so without one a dive with many photos comes
  // out shuffled.
  final keyed =
      <({int diveIndex, int position, int pk, Map<String, dynamic> entry})>[];
  for (final image in images) {
    final diveIndex = diveIndexByPk[image.diveFk];
    if (diveIndex == null) continue;
    final filename = _firstNonEmpty(image.path, image.originalPath);
    if (filename == null) continue;
    keyed.add((
      diveIndex: diveIndex,
      position: image.position,
      pk: image.pk,
      entry: macDiveMediaEntry(
        filename: filename,
        diveIndex: diveIndex,
        caption: image.caption,
      ),
    ));
  }
  keyed.sort((a, b) {
    final byDive = a.diveIndex.compareTo(b.diveIndex);
    if (byDive != 0) return byDive;
    final byPosition = a.position.compareTo(b.position);
    return byPosition != 0 ? byPosition : a.pk.compareTo(b.pk);
  });
  return [for (final k in keyed) k.entry];
}

/// Media entries for a native XML logbook. The reader already keeps each
/// dive's photos in document order, which is MacDive's display order.
List<Map<String, dynamic>> macDiveMediaEntriesFromXmlDives(
  List<MacDiveXmlDive> dives,
) {
  final out = <Map<String, dynamic>>[];
  for (var i = 0; i < dives.length; i++) {
    for (final photo in dives[i].photos) {
      out.add(
        macDiveMediaEntry(
          filename: photo.path,
          diveIndex: i,
          caption: photo.caption,
        ),
      );
    }
  }
  return out;
}

String? _firstNonEmpty(String? a, String? b) {
  if (a != null && a.trim().isNotEmpty) return a.trim();
  if (b != null && b.trim().isNotEmpty) return b.trim();
  return null;
}
