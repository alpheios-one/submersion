import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/universal_import/data/models/import_enums.dart';
import 'package:submersion/features/universal_import/data/parsers/macdive_xml_parser.dart';

void main() {
  test('MacDiveXmlParser emits media entries from <photos>', () async {
    final content = await File(
      'test/fixtures/macdive_xml/metric_small.xml',
    ).readAsString();
    final bytes = Uint8List.fromList(utf8.encode(content));

    final payload = await const MacDiveXmlParser().parse(bytes);

    final media = payload.entitiesOf(ImportEntityType.media);
    expect(media, hasLength(2));
    expect(media[0]['filename'], '/Users/test/Pictures/a.jpg');
    expect(media[0]['caption'], 'Shark');
    expect(media[0]['_diveIndex'], 0);
    expect(media[1]['filename'], '/Users/test/Pictures/b.jpg');
    expect(media[1]['caption'], isNull);
    expect(media[1]['_diveIndex'], 0);
    expect(media[0]['offsetSeconds'], isNull);
  });

  test('a logbook with no photos has no media group', () async {
    const xml = '''
<dives>
  <units>Metric</units>
  <dive>
    <identifier>abc</identifier>
    <date>2024-01-01 10:00:00</date>
  </dive>
</dives>
''';
    final payload = await const MacDiveXmlParser().parse(
      Uint8List.fromList(utf8.encode(xml)),
    );
    expect(payload.entities.containsKey(ImportEntityType.media), isFalse);
  });
}
