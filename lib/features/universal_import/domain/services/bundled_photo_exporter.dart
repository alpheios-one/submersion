import 'dart:io';

import 'package:path/path.dart' as p;

/// Copies a photo extracted from an imported archive into a folder the user
/// chose, and returns the path it now lives at.
///
/// Archive photos have no home of their own: the archive is the original and
/// the extracted copy sits in a temp folder the wizard deletes. Writing them
/// into a user-chosen folder gives them one that the user manages, so the
/// media row can link to the file in place like any other local photo,
/// instead of Submersion keeping a private copy.
///
/// The photo keeps its own filename. A file already there with the same
/// name and identical bytes is reused, so importing the same archive twice
/// does not multiply files; a different file with that name is left alone
/// and the new one gets a numbered name.
Future<String> exportBundledPhoto({
  required File source,
  required String destinationDir,
}) async {
  final dir = Directory(destinationDir);
  await dir.create(recursive: true);

  final name = p.basename(source.path);
  final stem = p.basenameWithoutExtension(name);
  final ext = p.extension(name);

  var candidate = p.join(dir.path, name);
  var counter = 1;
  while (true) {
    // Anything at all occupying the name blocks it, not just a file: a
    // directory or a symlink there would make the copy throw, or be
    // written through, and the photo would be lost to a log line.
    final type = FileSystemEntity.typeSync(candidate, followLinks: false);
    if (type == FileSystemEntityType.notFound) break;
    if (type == FileSystemEntityType.file &&
        await _sameBytes(File(candidate), source)) {
      return candidate;
    }
    candidate = p.join(dir.path, '${stem}_${counter++}$ext');
  }

  final copied = await source.copy(candidate);
  return copied.path;
}

/// Whether photos can actually be written under [dir]: the folder is
/// created if needed and a probe file is written and removed. Synchronous
/// so a picker callback can refuse a read-only choice on the spot instead
/// of letting every export fail after the import has already run.
bool folderAcceptsWrites(String dir) {
  try {
    final directory = Directory(dir);
    directory.createSync(recursive: true);
    final probe = File(
      p.join(
        dir,
        '.submersion_write_probe_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    probe.writeAsBytesSync(const [0]);
    probe.deleteSync();
    return true;
  } on FileSystemException {
    return false;
  }
}

/// Compares two files in fixed-size chunks so memory stays bounded no
/// matter how large the photo is.
Future<bool> _sameBytes(File a, File b) async {
  if (await a.length() != await b.length()) return false;
  final readerA = await a.open();
  try {
    final readerB = await b.open();
    try {
      while (true) {
        final chunkA = await readerA.read(_compareChunkBytes);
        final chunkB = await readerB.read(_compareChunkBytes);
        if (chunkA.length != chunkB.length) return false;
        if (chunkA.isEmpty) return true;
        for (var i = 0; i < chunkA.length; i++) {
          if (chunkA[i] != chunkB[i]) return false;
        }
      }
    } finally {
      await readerB.close();
    }
  } finally {
    await readerA.close();
  }
}

const _compareChunkBytes = 64 * 1024;
