import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:path/path.dart' as p;
import 'package:submersion/features/import_wizard/data/adapters/import_photo_linker.dart';
import 'package:submersion/features/import_wizard/data/adapters/resolved_photo_attachment.dart';
import 'package:submersion/features/media/data/services/local_file_link_service.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';

import 'import_photo_linker_test.mocks.dart';

MediaItem _item(String id) => MediaItem(
  id: id,
  mediaType: MediaType.photo,
  takenAt: DateTime(2024),
  createdAt: DateTime(2024),
  updatedAt: DateTime(2024),
);

@GenerateMocks([LocalFileLinkService])
void main() {
  late MockLocalFileLinkService service;
  late ImportPhotoLinker linker;

  setUp(() {
    service = MockLocalFileLinkService();
    linker = ImportPhotoLinker(service);
    when(service.linkedPathsForDive(any)).thenAnswer((_) async => <String>{});
    when(
      service.linkFileForDive(
        path: anyNamed('path'),
        diveId: anyNamed('diveId'),
        linkedPaths: anyNamed('linkedPaths'),
        takenAt: anyNamed('takenAt'),
        fallbackTakenAt: anyNamed('fallbackTakenAt'),
        latitude: anyNamed('latitude'),
        longitude: anyNamed('longitude'),
        caption: anyNamed('caption'),
      ),
    ).thenAnswer((_) async => _item('m'));
  });

  test('linkResolved passes every field of the attachment through', () async {
    await linker.linkResolved(
      ResolvedPhotoAttachment(
        file: File('/photos/a.jpg'),
        diveId: 'dive-1',
        takenAt: DateTime.utc(2025, 1, 15, 10, 3),
        diveStart: DateTime.utc(2025, 1, 15, 10),
        latitude: 1.5,
        longitude: 2.5,
        caption: 'Shark',
      ),
    );

    verify(
      service.linkFileForDive(
        path: '/photos/a.jpg',
        diveId: 'dive-1',
        linkedPaths: anyNamed('linkedPaths'),
        takenAt: DateTime.utc(2025, 1, 15, 10, 3),
        fallbackTakenAt: DateTime.utc(2025, 1, 15, 10),
        latitude: 1.5,
        longitude: 2.5,
        caption: 'Shark',
      ),
    ).called(1);
    expect(linker.alreadyLinked, 0);
  });

  test('looks up a dive\'s linked paths once, however many photos', () async {
    for (var i = 0; i < 3; i++) {
      await linker.linkResolved(
        ResolvedPhotoAttachment(file: File('/photos/$i.jpg'), diveId: 'dive-1'),
      );
    }
    await linker.linkResolved(
      ResolvedPhotoAttachment(file: File('/photos/x.jpg'), diveId: 'dive-2'),
    );

    verify(service.linkedPathsForDive('dive-1')).called(1);
    verify(service.linkedPathsForDive('dive-2')).called(1);
  });

  test('counts a null link result as already linked', () async {
    when(
      service.linkFileForDive(
        path: anyNamed('path'),
        diveId: anyNamed('diveId'),
        linkedPaths: anyNamed('linkedPaths'),
        takenAt: anyNamed('takenAt'),
        fallbackTakenAt: anyNamed('fallbackTakenAt'),
        latitude: anyNamed('latitude'),
        longitude: anyNamed('longitude'),
        caption: anyNamed('caption'),
      ),
    ).thenAnswer((_) async => null);

    await linker.linkResolved(
      ResolvedPhotoAttachment(file: File('/photos/a.jpg'), diveId: 'dive-1'),
    );
    await linker.linkResolved(
      ResolvedPhotoAttachment(file: File('/photos/b.jpg'), diveId: 'dive-1'),
    );

    expect(linker.alreadyLinked, 2);
  });

  test(
    'linkBundled writes the photo into the folder and links the copy',
    () async {
      final tmp = await Directory.systemTemp.createTemp('import_photo_linker_');
      addTearDown(() => tmp.delete(recursive: true));
      final extracted = File(p.join(tmp.path, 'extracted', 'IMG_1.jpg'));
      await extracted.create(recursive: true);
      await extracted.writeAsBytes([1, 2, 3]);
      final dest = p.join(tmp.path, 'chosen');

      await linker.linkBundled(
        file: extracted,
        diveId: 'dive-1',
        diveStart: DateTime.utc(2025, 1, 15, 10),
        destinationDir: dest,
      );

      final expected = p.join(dest, 'IMG_1.jpg');
      expect(File(expected).existsSync(), isTrue);
      verify(
        service.linkFileForDive(
          path: expected,
          diveId: 'dive-1',
          linkedPaths: anyNamed('linkedPaths'),
          takenAt: null,
          fallbackTakenAt: DateTime.utc(2025, 1, 15, 10),
          latitude: null,
          longitude: null,
          caption: null,
        ),
      ).called(1);
    },
  );
}
