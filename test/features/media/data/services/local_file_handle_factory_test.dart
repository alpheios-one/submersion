import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:submersion/features/media/data/services/local_bookmark_storage.dart';
import 'package:submersion/features/media/data/services/local_file_handle_factory.dart';
import 'package:submersion/features/media/data/services/local_media_platform.dart';

import 'local_file_handle_factory_test.mocks.dart';

@GenerateMocks([LocalBookmarkStorage, LocalMediaPlatform])
void main() {
  late MockLocalBookmarkStorage storage;
  late MockLocalMediaPlatform platform;

  setUp(() {
    storage = MockLocalBookmarkStorage();
    platform = MockLocalMediaPlatform();
  });

  test('plain-path platforms keep the path and mint no bookmark', () async {
    final factory = LocalFileHandleFactory(
      platform: platform,
      bookmarkStorage: storage,
      usesSecurityScopedBookmarks: false,
      keepsPathBesideBookmark: false,
    );

    final handle = await factory.create('/photos/a.jpg');

    expect(handle.localPath, '/photos/a.jpg');
    expect(handle.bookmarkRef, isNull);
    verifyNever(platform.createBookmark(any));
    verifyNever(storage.write(any, any));
  });

  test('bookmark platforms store the blob under a fresh ref', () async {
    final blob = Uint8List.fromList([1, 2, 3]);
    when(
      platform.createBookmark('/photos/a.jpg'),
    ).thenAnswer((_) async => blob);
    when(storage.write(any, any)).thenAnswer((_) async {});
    final factory = LocalFileHandleFactory(
      platform: platform,
      bookmarkStorage: storage,
      usesSecurityScopedBookmarks: true,
      keepsPathBesideBookmark: false,
    );

    final handle = await factory.create('/photos/a.jpg');

    expect(handle.bookmarkRef, isNotNull);
    expect(handle.bookmarkRef, isNotEmpty);
    // iOS: the picker path is sandbox-scoped and not reusable.
    expect(handle.localPath, isNull);
    verify(storage.write(handle.bookmarkRef!, blob)).called(1);
  });

  test('macOS keeps the path beside the bookmark', () async {
    when(platform.createBookmark(any)).thenAnswer((_) async => Uint8List(0));
    when(storage.write(any, any)).thenAnswer((_) async {});
    final factory = LocalFileHandleFactory(
      platform: platform,
      bookmarkStorage: storage,
      usesSecurityScopedBookmarks: true,
      keepsPathBesideBookmark: true,
    );

    final handle = await factory.create('/photos/a.jpg');

    expect(handle.localPath, '/photos/a.jpg');
    expect(handle.bookmarkRef, isNotNull);
  });

  test('two handles never share a bookmark ref', () async {
    when(platform.createBookmark(any)).thenAnswer((_) async => Uint8List(0));
    when(storage.write(any, any)).thenAnswer((_) async {});
    final factory = LocalFileHandleFactory(
      platform: platform,
      bookmarkStorage: storage,
      usesSecurityScopedBookmarks: true,
    );

    final a = await factory.create('/photos/a.jpg');
    final b = await factory.create('/photos/b.jpg');

    expect(a.bookmarkRef, isNot(b.bookmarkRef));
  });
}
