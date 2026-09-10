import 'dart:io';

/// One photo the import wizard resolved on disk, ready to be linked to a
/// dive. Handed to the attach callback of `attachResolvedPhotos` so the
/// callback's shape does not change every time a source learns to carry
/// one more field.
class ResolvedPhotoAttachment {
  /// The file on this device, as resolved against the picked folder.
  final File file;

  /// The dive the source attached the photo to.
  final String diveId;

  /// A capture time the source itself asserted (a Subsurface picture's
  /// offset from dive start). Null when the source recorded none, in which
  /// case the linker falls back to the file's EXIF time and then to
  /// [diveStart].
  final DateTime? takenAt;

  /// Start of the owning dive, the last-resort capture time.
  final DateTime? diveStart;

  /// The photo's own coordinates when the source recorded them, which is
  /// not the same as the dive site's.
  final double? latitude;
  final double? longitude;

  /// The source's caption for the photo, when it had one.
  final String? caption;

  const ResolvedPhotoAttachment({
    required this.file,
    required this.diveId,
    this.takenAt,
    this.diveStart,
    this.latitude,
    this.longitude,
    this.caption,
  });
}
