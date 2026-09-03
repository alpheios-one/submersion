import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:submersion/features/universal_import/domain/services/bundled_photo_exporter.dart';

void main() {
  late Directory tmp;
  late Directory dest;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('bundled_photo_export_');
    dest = Directory(p.join(tmp.path, 'chosen'));
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<File> source(String name, List<int> bytes) async {
    final f = File(p.join(tmp.path, 'extracted', name));
    await f.create(recursive: true);
    return f.writeAsBytes(bytes);
  }

  test('copies the photo into the chosen folder under its own name', () async {
    final src = await source('IMG_0001.jpg', [1, 2, 3]);

    final out = await exportBundledPhoto(
      source: src,
      destinationDir: dest.path,
    );

    expect(out, p.join(dest.path, 'IMG_0001.jpg'));
    expect(await File(out).readAsBytes(), [1, 2, 3]);
    // The extracted copy is untouched; the caller owns its lifetime.
    expect(src.existsSync(), isTrue);
  });

  test('creates the chosen folder when it does not exist yet', () async {
    final src = await source('a.jpg', [9]);
    final nested = p.join(dest.path, 'Dives', '2025');

    final out = await exportBundledPhoto(source: src, destinationDir: nested);

    expect(File(out).existsSync(), isTrue);
    expect(p.dirname(out), nested);
  });

  test('reuses an identical file already in the folder', () async {
    final src = await source('a.jpg', [1, 2, 3]);
    await dest.create(recursive: true);
    final existing = File(p.join(dest.path, 'a.jpg'));
    await existing.writeAsBytes([1, 2, 3]);
    final before = await existing.lastModified();

    final out = await exportBundledPhoto(
      source: src,
      destinationDir: dest.path,
    );

    expect(out, existing.path);
    expect(await existing.lastModified(), before);
    expect(dest.listSync().length, 1);
  });

  test('a different file with the same name gets a numbered name', () async {
    final src = await source('a.jpg', [1, 2, 3]);
    await dest.create(recursive: true);
    await File(p.join(dest.path, 'a.jpg')).writeAsBytes([7, 7, 7]);
    await File(p.join(dest.path, 'a_1.jpg')).writeAsBytes([8, 8, 8]);

    final out = await exportBundledPhoto(
      source: src,
      destinationDir: dest.path,
    );

    expect(out, p.join(dest.path, 'a_2.jpg'));
    expect(await File(out).readAsBytes(), [1, 2, 3]);
    // Neither existing file was overwritten.
    expect(await File(p.join(dest.path, 'a.jpg')).readAsBytes(), [7, 7, 7]);
  });

  test(
    'compares files larger than one chunk without loading them whole',
    () async {
      // Three chunks plus a tail, differing only in the final byte.
      final big = List<int>.generate(64 * 1024 * 3 + 17, (i) => i % 251);
      final src = await source('big.jpg', big);
      await dest.create(recursive: true);
      await File(p.join(dest.path, 'big.jpg')).writeAsBytes(big);
      final almost = List<int>.of(big)..[big.length - 1] = 0;
      await File(p.join(dest.path, 'big_1.jpg')).writeAsBytes(almost);

      final out = await exportBundledPhoto(
        source: src,
        destinationDir: dest.path,
      );

      // The identical multi-chunk file is reused; the near-identical one is
      // not mistaken for it.
      expect(out, p.join(dest.path, 'big.jpg'));
      expect(dest.listSync().length, 2);
    },
  );

  test('a directory holding the photo name is stepped over', () async {
    final src = await source('a.jpg', [1, 2, 3]);
    await Directory(p.join(dest.path, 'a.jpg')).create(recursive: true);

    final out = await exportBundledPhoto(
      source: src,
      destinationDir: dest.path,
    );

    expect(out, p.join(dest.path, 'a_1.jpg'));
    expect(await File(out).readAsBytes(), [1, 2, 3]);
  });

  test('a dangling symlink holding the photo name is stepped over', () async {
    final src = await source('a.jpg', [1, 2, 3]);
    await dest.create(recursive: true);
    await Link(
      p.join(dest.path, 'a.jpg'),
    ).create(p.join(dest.path, 'nothing-here.jpg'));

    final out = await exportBundledPhoto(
      source: src,
      destinationDir: dest.path,
    );

    expect(out, p.join(dest.path, 'a_1.jpg'));
    expect(await File(out).readAsBytes(), [1, 2, 3]);
  });

  group('folderAcceptsWrites', () {
    test('a writable folder is accepted and left without a probe file', () {
      final dir = p.join(tmp.path, 'new', 'nested');
      expect(folderAcceptsWrites(dir), isTrue);
      expect(Directory(dir).listSync(), isEmpty);
    });

    test('an unusable path is refused rather than thrown from', () {
      // A NUL byte makes dart:io throw ArgumentError, not a
      // FileSystemException; the question being asked is still just
      // "can photos go here", and the answer is still no.
      expect(folderAcceptsWrites('${tmp.path}/bad\u0000name'), isFalse);
    });

    test('a read-only folder is refused', () {
      if (Platform.isWindows) {
        markTestSkipped('POSIX permission bits are not honoured on Windows');
        return;
      }
      final dir = Directory(p.join(tmp.path, 'readonly'))..createSync();
      Process.runSync('chmod', ['000', dir.path]);
      addTearDown(() => Process.runSync('chmod', ['755', dir.path]));
      if (folderAcceptsWrites(dir.path)) {
        // Root ignores permission bits; nothing to assert then.
        markTestSkipped('running with permissions that bypass chmod');
        return;
      }
      expect(folderAcceptsWrites(dir.path), isFalse);
    });
  });
}
