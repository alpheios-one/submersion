import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:submersion/features/media/data/repositories/media_repository.dart';
import 'package:submersion/features/media/data/services/local_bookmark_storage.dart';
import 'package:submersion/features/media/data/services/local_file_handle_factory.dart';
import 'package:submersion/features/media/data/services/local_file_link_service.dart';
import 'package:submersion/features/media/data/services/local_media_platform.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/domain/entities/media_source_type.dart';
import 'package:submersion/features/media/domain/value_objects/media_source_metadata.dart';

import 'local_file_link_service_test.mocks.dart';

MediaItem _saved(MediaItem item) => item.copyWith(
  id: 'media-${item.originalFilename}',
  createdAt: DateTime(2024),
  updatedAt: DateTime(2024),
);

@GenerateMocks([MediaRepository, LocalBookmarkStorage, LocalMediaPlatform])
void main() {
  late MockMediaRepository repo;
  late List<String> created;

  LocalFileLinkService service({
    MediaSourceMetadata? metadata,
    bool metadataThrows = false,
  }) {
    return LocalFileLinkService(
      mediaRepository: repo,
      handles: LocalFileHandleFactory(
        platform: MockLocalMediaPlatform(),
        bookmarkStorage: MockLocalBookmarkStorage(),
        usesSecurityScopedBookmarks: false,
        keepsPathBesideBookmark: false,
      ),
      readMetadata: (File file) async {
        if (metadataThrows) throw StateError('unreadable');
        return metadata;
      },
      onMediaCreated: created.add,
    );
  }

  setUp(() {
    repo = MockMediaRepository();
    created = [];
    when(repo.createMedia(any)).thenAnswer(
      (inv) async => _saved(inv.positionalArguments.first as MediaItem),
    );
  });

  test('links the file in place as a localFile row, copying nothing', () async {
    final linked = <String>{};
    final item = await service().linkFileForDive(
      path: '/photos/shark.jpg',
      diveId: 'dive-1',
      linkedPaths: linked,
      caption: 'Shark!',
      fallbackTakenAt: DateTime.utc(2025, 1, 15, 10),
    );

    expect(item, isNotNull);
    final saved =
        verify(repo.createMedia(captureAny)).captured.single as MediaItem;
    expect(saved.sourceType, MediaSourceType.localFile);
    expect(saved.localPath, '/photos/shark.jpg');
    // No app-owned copy: filePath is the copy slot and stays empty.
    expect(saved.filePath, isNull);
    expect(saved.diveId, 'dive-1');
    expect(saved.originalFilename, 'shark.jpg');
    expect(saved.caption, 'Shark!');
    expect(saved.mediaType, MediaType.photo);
    expect(saved.takenAt, DateTime.utc(2025, 1, 15, 10));
    expect(linked, contains('/photos/shark.jpg'));
    expect(created, ['media-shark.jpg']);
  });

  test('an already-linked path is skipped and nothing is written', () async {
    final linked = <String>{'/photos/shark.jpg'};
    final item = await service().linkFileForDive(
      path: '/photos/shark.jpg',
      diveId: 'dive-1',
      linkedPaths: linked,
    );

    expect(item, isNull);
    verifyNever(repo.createMedia(any));
    expect(created, isEmpty);
  });

  test('a source-asserted time beats EXIF, which beats the fallback', () async {
    final exif = MediaSourceMetadata(
      mimeType: 'image/jpeg',
      takenAt: DateTime.utc(2025, 1, 15, 10, 30),
      latitude: 1.5,
      longitude: 2.5,
      width: 4000,
      height: 3000,
    );

    await service(metadata: exif).linkFileForDive(
      path: '/photos/a.jpg',
      diveId: 'dive-1',
      linkedPaths: {},
      takenAt: DateTime.utc(2025, 1, 15, 10, 3, 20),
      fallbackTakenAt: DateTime.utc(2025, 1, 15, 10),
    );
    await service(metadata: exif).linkFileForDive(
      path: '/photos/b.jpg',
      diveId: 'dive-1',
      linkedPaths: {},
      fallbackTakenAt: DateTime.utc(2025, 1, 15, 10),
    );

    final saved = verify(
      repo.createMedia(captureAny),
    ).captured.cast<MediaItem>();
    expect(saved[0].takenAt, DateTime.utc(2025, 1, 15, 10, 3, 20));
    expect(saved[1].takenAt, DateTime.utc(2025, 1, 15, 10, 30));
    // EXIF fills in what the caller did not assert.
    expect(saved[1].latitude, 1.5);
    expect(saved[1].longitude, 2.5);
    expect(saved[1].width, 4000);
    expect(saved[1].height, 3000);
  });

  test('a video mime type makes a video row', () async {
    await service(
      metadata: const MediaSourceMetadata(mimeType: 'video/mp4'),
    ).linkFileForDive(
      path: '/photos/clip.mp4',
      diveId: 'dive-1',
      linkedPaths: {},
    );
    final saved =
        verify(repo.createMedia(captureAny)).captured.single as MediaItem;
    expect(saved.mediaType, MediaType.video);
  });

  test('unreadable metadata does not block the link', () async {
    final item = await service(metadataThrows: true).linkFileForDive(
      path: '/photos/a.jpg',
      diveId: 'dive-1',
      linkedPaths: {},
      fallbackTakenAt: DateTime.utc(2025),
    );
    expect(item, isNotNull);
    final saved =
        verify(repo.createMedia(captureAny)).captured.single as MediaItem;
    expect(saved.takenAt, DateTime.utc(2025));
  });

  test(
    'a repository failure propagates and leaves the path unlinked',
    () async {
      when(repo.createMedia(any)).thenThrow(StateError('db closed'));
      final linked = <String>{};
      await expectLater(
        service().linkFileForDive(
          path: '/photos/a.jpg',
          diveId: 'dive-1',
          linkedPaths: linked,
        ),
        throwsStateError,
      );
      expect(linked, isEmpty);
      expect(created, isEmpty);
    },
  );

  test('linkedPathsForDive reads the repository', () async {
    when(
      repo.getLinkedLocalPathsForDive('dive-1'),
    ).thenAnswer((_) async => {'/photos/x.jpg'});
    expect(await service().linkedPathsForDive('dive-1'), {'/photos/x.jpg'});
  });
}
