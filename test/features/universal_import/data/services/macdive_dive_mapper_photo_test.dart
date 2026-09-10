import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/universal_import/data/models/import_enums.dart';
import 'package:submersion/features/universal_import/data/services/macdive_dive_mapper.dart';
import 'package:submersion/features/universal_import/data/services/macdive_raw_types.dart';

MacDiveRawLogbook _logbook({
  required List<MacDiveRawDive> dives,
  required List<MacDiveRawDiveImage> images,
}) {
  return MacDiveRawLogbook(
    dives: dives,
    sitesByPk: const {},
    buddiesByPk: const {},
    tagsByPk: const {},
    gearByPk: const {},
    tanksByPk: const {},
    gasesByPk: const {},
    tankAndGases: const [],
    crittersByPk: const {},
    certifications: const [],
    serviceRecords: const [],
    events: const [],
    diveImages: images,
    diveToBuddyPks: const {},
    diveToTagPks: const {},
    diveToGearPks: const {},
    diveToCritterPks: const {},
    unitsPreference: 'Metric',
  );
}

void main() {
  test('maps ZDIVEIMAGE rows to media entries keyed by dive index', () async {
    final payload = await MacDiveDiveMapper.toPayload(
      _logbook(
        dives: const [
          MacDiveRawDive(pk: 10, uuid: 'dive-uuid-1'),
          MacDiveRawDive(pk: 20, uuid: 'dive-uuid-2'),
        ],
        images: const [
          MacDiveRawDiveImage(
            pk: 1,
            uuid: 'img-1',
            diveFk: 20,
            position: 0,
            path: 'E963EE6B-C4C8-4CC6-B956-02374F950EB7.jpg',
          ),
          MacDiveRawDiveImage(
            pk: 2,
            uuid: 'img-2',
            diveFk: 10,
            position: 1,
            path: '/Users/test/Pictures/Diving/turtle.jpg',
          ),
          MacDiveRawDiveImage(
            pk: 3,
            uuid: 'img-3',
            diveFk: 10,
            position: 0,
            caption: 'Shark!',
            path: '/Users/test/Pictures/Diving/shark.jpg',
            originalPath: '/old/shark.jpg',
          ),
        ],
      ),
    );

    final media = payload.entitiesOf(ImportEntityType.media);
    expect(media, hasLength(3));
    // Ordered by dive, then by MacDive's display position.
    expect(media[0]['filename'], '/Users/test/Pictures/Diving/shark.jpg');
    expect(media[0]['caption'], 'Shark!');
    expect(media[0]['_diveIndex'], 0);
    expect(media[1]['filename'], '/Users/test/Pictures/Diving/turtle.jpg');
    expect(media[1]['caption'], isNull);
    expect(media[1]['_diveIndex'], 0);
    expect(media[2]['filename'], 'E963EE6B-C4C8-4CC6-B956-02374F950EB7.jpg');
    expect(media[2]['_diveIndex'], 1);
    // MacDive records no capture offset or photo coordinates.
    expect(media[0]['offsetSeconds'], isNull);
    expect(media[0]['latitude'], isNull);
    expect(media[0]['longitude'], isNull);
  });

  test('drops photos whose dive FK matches no dive', () async {
    final payload = await MacDiveDiveMapper.toPayload(
      _logbook(
        dives: const [MacDiveRawDive(pk: 1, uuid: 'dive-uuid-1')],
        images: const [
          MacDiveRawDiveImage(
            pk: 9,
            uuid: 'img-9',
            diveFk: 999,
            path: '/x.jpg',
          ),
        ],
      ),
    );
    expect(payload.entitiesOf(ImportEntityType.media), isEmpty);
    expect(payload.entities.containsKey(ImportEntityType.media), isFalse);
  });

  test(
    'falls back to originalPath when path is empty; drops when both are',
    () async {
      final payload = await MacDiveDiveMapper.toPayload(
        _logbook(
          dives: const [MacDiveRawDive(pk: 1, uuid: 'dive-uuid-1')],
          images: const [
            MacDiveRawDiveImage(
              pk: 1,
              uuid: 'img-1',
              diveFk: 1,
              originalPath: '/orig/only.jpg',
            ),
            MacDiveRawDiveImage(pk: 2, uuid: 'img-2', diveFk: 1),
          ],
        ),
      );
      final media = payload.entitiesOf(ImportEntityType.media);
      expect(media, hasLength(1));
      expect(media.single['filename'], '/orig/only.jpg');
    },
  );

  test('photos with no recorded position keep MacDive row order', () async {
    // Dart's sort is only stable up to 32 elements, and MacDive leaves
    // ZPOSITION null for almost every row (259 of 261 in the real sample),
    // so without a tiebreaker a dive with many photos shuffles.
    const count = 40;
    final payload = await MacDiveDiveMapper.toPayload(
      _logbook(
        dives: const [MacDiveRawDive(pk: 1, uuid: 'dive-uuid-1')],
        images: [
          for (var i = 0; i < count; i++)
            MacDiveRawDiveImage(
              pk: i + 1,
              uuid: 'img-$i',
              diveFk: 1,
              path: 'photo_$i.jpg',
            ),
        ],
      ),
    );

    final media = payload.entitiesOf(ImportEntityType.media);
    expect(media, hasLength(count));
    expect(
      [for (final m in media) m['filename']],
      [for (var i = 0; i < count; i++) 'photo_$i.jpg'],
    );
  });

  test('positioned photos lead, unpositioned follow in row order', () async {
    // MacDive leaves ZPOSITION null for nearly every photo, so an
    // unpositioned row means "no recorded place", not "place 0".
    final payload = await MacDiveDiveMapper.toPayload(
      _logbook(
        dives: const [MacDiveRawDive(pk: 1, uuid: 'dive-uuid-1')],
        images: const [
          MacDiveRawDiveImage(pk: 3, uuid: 'c', diveFk: 1, path: 'c.jpg'),
          MacDiveRawDiveImage(pk: 1, uuid: 'a', diveFk: 1, path: 'a.jpg'),
          MacDiveRawDiveImage(
            pk: 9,
            uuid: 'p',
            diveFk: 1,
            position: 1,
            path: 'positioned.jpg',
          ),
        ],
      ),
    );

    expect(
      [
        for (final m in payload.entitiesOf(ImportEntityType.media))
          m['filename'],
      ],
      ['positioned.jpg', 'a.jpg', 'c.jpg'],
    );
  });
}
