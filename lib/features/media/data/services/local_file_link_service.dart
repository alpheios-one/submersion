import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:submersion/core/services/logger_service.dart';
import 'package:submersion/features/media/data/repositories/media_repository.dart';
import 'package:submersion/features/media/data/services/local_file_handle_factory.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/domain/entities/media_source_type.dart';
import 'package:submersion/features/media/domain/value_objects/media_source_metadata.dart';

/// Reads capture metadata for a file about to be linked. Null when the file
/// cannot be read; the link still happens, with the caller's fallbacks.
typedef LocalFileMetadataReader =
    Future<MediaSourceMetadata?> Function(File file);

/// Links a file on this device to a dive as a `localFile` media row that
/// references the file in place.
///
/// Nothing is copied: the row stores the [LocalFileHandle] the factory
/// mints, so the photo lives wherever the user keeps it and Submersion
/// never touches the original. This is the import wizard's counterpart to
/// the Files tab's persistence, built on the same handle factory so the
/// two cannot drift.
class LocalFileLinkService {
  LocalFileLinkService({
    required MediaRepository mediaRepository,
    required LocalFileHandleFactory handles,
    required LocalFileMetadataReader readMetadata,
    this.onMediaCreated,
  }) : _mediaRepository = mediaRepository,
       _handles = handles,
       _readMetadata = readMetadata;

  final MediaRepository _mediaRepository;
  final LocalFileHandleFactory _handles;
  final LocalFileMetadataReader _readMetadata;
  final _log = LoggerService.forClass(LocalFileLinkService);

  /// Invoked after every successful createMedia so the media store can
  /// enqueue an upload. Null when no store is configured.
  final void Function(String mediaId)? onMediaCreated;

  /// The local paths already linked to [diveId], the dedupe key for
  /// [linkFileForDive]. Fetch once per dive and pass the same set to every
  /// link for that dive; the service adds each new path to it.
  ///
  /// iOS rows carry only a bookmark, no path, so they are invisible here.
  /// That is fine while the wizard's Photos step is desktop-only; a mobile
  /// Photos step would need a bookmark-aware dedupe before shipping.
  Future<Set<String>> linkedPathsForDive(String diveId) =>
      _mediaRepository.getLinkedLocalPathsForDive(diveId);

  /// Links [path] to [diveId], or returns null when [linkedPaths] already
  /// holds the path so a re-run of the same import never double-links.
  ///
  /// [takenAt] is a capture time the source asserted (a logbook's own
  /// offset from dive start); it wins over the file's EXIF time, which wins
  /// over [fallbackTakenAt] (typically the dive start), which wins over
  /// now. [latitude] and [longitude] follow the same rule against EXIF.
  Future<MediaItem?> linkFileForDive({
    required String path,
    required String diveId,
    required Set<String> linkedPaths,
    DateTime? takenAt,
    DateTime? fallbackTakenAt,
    double? latitude,
    double? longitude,
    String? caption,
  }) async {
    if (linkedPaths.contains(path)) {
      _log.info('Skipping already-linked $path for dive $diveId');
      return null;
    }

    MediaSourceMetadata? metadata;
    try {
      metadata = await _readMetadata(File(path));
    } catch (e) {
      // Metadata is a nicety; the link itself must not depend on a
      // readable EXIF block.
      _log.warning('Could not read metadata for $path: $e');
    }

    final handle = await _handles.create(path);
    final now = DateTime.now();
    final mimeType = metadata?.mimeType ?? '';
    final item = MediaItem(
      // Empty id triggers UUID generation in MediaRepository.createMedia.
      id: '',
      diveId: diveId,
      mediaType: mimeType.startsWith('video/')
          ? MediaType.video
          : MediaType.photo,
      sourceType: MediaSourceType.localFile,
      originalFilename: p.basename(path),
      localPath: handle.localPath,
      bookmarkRef: handle.bookmarkRef,
      caption: caption,
      takenAt: takenAt ?? metadata?.takenAt ?? fallbackTakenAt ?? now,
      latitude: latitude ?? metadata?.latitude,
      longitude: longitude ?? metadata?.longitude,
      width: metadata?.width,
      height: metadata?.height,
      durationSeconds: metadata?.durationSeconds,
      createdAt: now,
      updatedAt: now,
    );

    final saved = await _mediaRepository.createMedia(item);
    linkedPaths.add(path);
    onMediaCreated?.call(saved.id);
    return saved;
  }
}
