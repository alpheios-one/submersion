import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/universal_import/data/services/macdive_xml_reader.dart';

void main() {
  test(
    'reads <photos><photo> with path + caption and assigns positions',
    () async {
      final content = await File(
        'test/fixtures/macdive_xml/metric_small.xml',
      ).readAsString();
      final dive = MacDiveXmlReader.parse(content).dives.first;

      expect(dive.photos.length, 2);
      expect(dive.photos[0].path, '/Users/test/Pictures/a.jpg');
      expect(dive.photos[0].caption, 'Shark');
      expect(dive.photos[0].position, 0);
      expect(dive.photos[1].path, '/Users/test/Pictures/b.jpg');
      expect(dive.photos[1].caption, isNull);
      expect(dive.photos[1].position, 1);
    },
  );

  test('a photo with no path is skipped but keeps later positions stable', () {
    const xml = '''
<dives>
  <dive>
    <identifier>abc</identifier>
    <date>2024-01-01 10:00:00</date>
    <photos>
      <photo><caption>no path</caption></photo>
      <photo><path>/p/b.jpg</path></photo>
    </photos>
  </dive>
</dives>
''';
    final dive = MacDiveXmlReader.parse(xml).dives.first;
    expect(dive.photos.length, 1);
    expect(dive.photos.single.path, '/p/b.jpg');
    expect(dive.photos.single.position, 1);
  });

  test('a dive without <photos> has an empty list', () {
    const xml = '''
<dives>
  <dive>
    <identifier>abc</identifier>
    <date>2024-01-01 10:00:00</date>
  </dive>
</dives>
''';
    expect(MacDiveXmlReader.parse(xml).dives.first.photos, isEmpty);
  });
}
