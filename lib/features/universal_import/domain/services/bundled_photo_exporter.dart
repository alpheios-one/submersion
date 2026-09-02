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

  var candidate = File(p.join(dir.path, name));
  var counter = 1;
  while (candidate.existsSync()) {
    if (await _sameBytes(candidate, source)) return candidate.path;
    candidate = File(p.join(dir.path, '${stem}_${counter++}$ext'));
  }

  final copied = await source.copy(candidate.path);
  return copied.path;
}

/// Compares two files in fixed-size chunks so memory stays bounded no
/// matter how large the photo is.
Future<bool> _sameBytes(File a, File b) async {
  if (await a.length() != await b.length()) return false;
  final readerA = await a.open();
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
    await readerA.close();
    await readerB.close();
  }
}

const _compareChunkBytes = 64 * 1024;
