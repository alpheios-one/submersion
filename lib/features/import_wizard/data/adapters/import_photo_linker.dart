import 'dart:io';

import 'package:submersion/features/import_wizard/data/adapters/resolved_photo_attachment.dart';
import 'package:submersion/features/media/data/services/local_file_link_service.dart';
import 'package:submersion/features/universal_import/domain/services/bundled_photo_exporter.dart';

/// Links an import's photos to their dives in place, for one import run.
///
/// Wraps [LocalFileLinkService] with the two things every attach loop in
/// the wizard needs and none should reimplement: one dedupe lookup per
/// dive rather than per photo, and a count of the photos that were already
/// linked so the summary reports only what this run actually added.
class ImportPhotoLinker {
  ImportPhotoLinker(this._linker);

  final LocalFileLinkService _linker;
  final _linkedPathsByDive = <String, Set<String>>{};
  var _alreadyLinked = 0;

  /// Photos handed to a link call that were already on their dive. The
  /// attach loops count such a call as a success (nothing failed), so the
  /// caller subtracts this to get the number of new links.
  int get alreadyLinked => _alreadyLinked;

  /// A photo extracted from an archive: written into [destinationDir] under
  /// its own name first, because the extracted copy lives in a temp folder
  /// the wizard deletes, then linked from its new home.
  /// [diveStart] is the owning dive's start time, the last-resort capture
  /// time: an archive records no per-photo offset, so this is a fallback
  /// and never an asserted capture time.
  Future<void> linkBundled({
    required File file,
    required String diveId,
    required DateTime? diveStart,
    required String destinationDir,
  }) async {
    final path = await exportBundledPhoto(
      source: file,
      destinationDir: destinationDir,
    );
    await _link(path: path, diveId: diveId, fallbackTakenAt: diveStart);
  }

  /// A photo the logbook referenced by path, resolved on this device: it
  /// stays where the user keeps it and is linked in place.
  Future<void> linkResolved(ResolvedPhotoAttachment photo) => _link(
    path: photo.file.path,
    diveId: photo.diveId,
    takenAt: photo.takenAt,
    fallbackTakenAt: photo.diveStart,
    latitude: photo.latitude,
    longitude: photo.longitude,
    caption: photo.caption,
  );

  Future<void> _link({
    required String path,
    required String diveId,
    DateTime? takenAt,
    DateTime? fallbackTakenAt,
    double? latitude,
    double? longitude,
    String? caption,
  }) async {
    final linked = _linkedPathsByDive[diveId] ??= await _linker
        .linkedPathsForDive(diveId);
    final item = await _linker.linkFileForDive(
      path: path,
      diveId: diveId,
      linkedPaths: linked,
      takenAt: takenAt,
      fallbackTakenAt: fallbackTakenAt,
      latitude: latitude,
      longitude: longitude,
      caption: caption,
    );
    if (item == null) _alreadyLinked++;
  }
}
