import 'package:submersion/features/media/domain/entities/media_provenance.dart';

/// What a grid tile's status badge should say about one item.
///
/// Deliberately quiet: a healthy, backed-up item renders nothing, so a badge
/// on screen always means "look at me" rather than decorating every
/// thumbnail.
enum MediaStatus {
  /// Nothing worth saying.
  none,

  /// The source is gone and nothing can display this item.
  broken,

  /// The upload gave up.
  transferFailed,

  /// An upload is running now.
  transferring,

  /// An upload is waiting to run.
  queued,

  /// The local copy is gone but the cloud store can serve it, so viewing
  /// this item streams rather than reading from disk.
  cloudOnly,

  /// A store is attached and holds nothing for this item.
  notBackedUp,
}

/// Picks the single most important thing to say about [provenance].
///
/// Ordered, first match wins. Two orderings here are load-bearing:
///
/// Transfer states sit ABOVE [MediaStatus.notBackedUp]. A queued item is by
/// definition not yet backed up, so the reverse order would render every
/// in-flight upload as `cloud_off` and the transfer glyph would never appear.
///
/// [MediaStatus.broken] sits above the eligibility gate, so a dead URL still
/// reports that it is dead instead of going silent, and it is the one state
/// that renders without a store attached.
MediaStatus mediaStatusFor(MediaProvenance provenance) {
  final missing = provenance.origin.health == OriginHealth.missing;
  final backup = provenance.backup;
  // Reachable here, not merely uploaded somewhere: bytes in a store this
  // device cannot talk to cannot cover for a missing local file.
  final coveredByStore = backup.tier != BackupTier.none && backup.storeAttached;

  if (missing && !coveredByStore) return MediaStatus.broken;

  // Below this line everything is about backing up, which a source the
  // pipeline would never carry is not a candidate for. Saying "not backed
  // up" about a web link would report a problem the user cannot act on.
  if (!backup.eligible) return MediaStatus.none;

  switch (backup.queueState) {
    case 'failed':
      return MediaStatus.transferFailed;
    case 'transferring':
      return MediaStatus.transferring;
    case 'pending':
      return MediaStatus.queued;
    default:
      // 'done' or no row at all: nothing in flight, fall through to the
      // resting state.
      break;
  }

  if (missing) return MediaStatus.cloudOnly;
  if (backup.storeAttached && backup.tier == BackupTier.none) {
    return MediaStatus.notBackedUp;
  }
  return MediaStatus.none;
}
