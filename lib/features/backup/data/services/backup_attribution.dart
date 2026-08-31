import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Which device wrote a backup file.
enum BackupOwnership {
  /// Written by this device. Safe to offer for deletion once its history
  /// record is gone.
  thisDevice,

  /// Written by a different device. Never offer to delete it: in a shared
  /// backup folder this may be that device's only copy.
  otherDevice,

  /// No attribution in the name. Every backup written before attribution
  /// shipped is in this state, and so is anything that is not one of ours.
  unattributed,
}

/// Marker separating the timestamp from the device tag.
///
/// Two underscores, because the timestamp itself contains single ones and the
/// historic name is `submersion_backup_<date>_<time>.db`.
const String _deviceMarker = '__d';

const String _backupPrefix = 'submersion_backup_';

/// Extensions a backup artifact can carry: the plaintext `.db` and the
/// encrypted framed variant (`BackupCrypto.fileExtension`). Named here rather
/// than imported so this module depends on nothing but a string; a test pins
/// the set against the crypto constant.
const Set<String> backupFileExtensions = {'.db', '.sbe'};

/// A tag is exactly eight lowercase hex digits, the prefix of a SHA-1.
final RegExp _tagPattern = RegExp(r'^[0-9a-f]{8}$');

/// A short, stable, filesystem-safe tag for [deviceId].
///
/// Hashed rather than truncated so nothing about the device identity leaks
/// into a filename that may sync to a shared cloud folder, and so an id
/// containing separators or spaces cannot produce an unusable name.
String deviceTag(String deviceId) =>
    sha1.convert(utf8.encode(deviceId)).toString().substring(0, 8);

/// Builds a backup filename that records which device wrote it.
///
/// Attribution lives in the NAME, not in the `BackupRecord`, on purpose. An
/// orphaned backup is by definition a file whose record has been lost, so a
/// device id stored in the record is exactly the information that is already
/// missing. The name is the only part that survives losing SharedPreferences.
///
/// The historic prefix and extension are preserved so the cloud listing
/// (`namePattern: 'submersion_backup_'`) and the plaintext-cleanup glob
/// (`submersion_backup_*.db`) keep working untouched.
String buildBackupFilename({
  required String timestamp,
  required String deviceId,
  String extension = '.db',
}) => '$_backupPrefix$timestamp$_deviceMarker${deviceTag(deviceId)}$extension';

/// The device tag embedded in [filename], or null when it carries none.
///
/// Null covers three cases that all mean the same thing for safety: a backup
/// written before attribution shipped, a file this app did not write, and a
/// name that has been renamed by hand.
String? backupDeviceTagFromFilename(String filename) {
  if (!filename.startsWith(_backupPrefix)) return null;

  // A backup extension is required, and the tag has to run to the end of the
  // stem. A directory scan sees whatever else the folder holds, and sidecars
  // borrow a real backup's name: `...__dabcd1234.db.tmp` from an interrupted
  // write, `...__dabcd1234 (conflicted copy).db` from a sync client. Reading a
  // tag out of one of those would claim a file we did not write, which is the
  // single outcome this module exists to prevent.
  final extension = backupFileExtensions.firstWhere(
    filename.endsWith,
    orElse: () => '',
  );
  if (extension.isEmpty) return null;

  final stem = filename.substring(0, filename.length - extension.length);
  final marker = stem.lastIndexOf(_deviceMarker);
  if (marker < 0) return null;

  final tag = stem.substring(marker + _deviceMarker.length);
  return _tagPattern.hasMatch(tag) ? tag : null;
}

/// Who wrote [filename], from the name alone.
///
/// Deliberately conservative: anything that is not provably this device's is
/// [BackupOwnership.otherDevice] or [BackupOwnership.unattributed], and
/// neither may be offered for deletion. The cost of a false
/// [BackupOwnership.thisDevice] is destroying someone's only backup; the cost
/// of a false negative is a file the user tidies up themselves.
BackupOwnership classifyBackupFile({
  required String filename,
  required String thisDeviceId,
}) {
  final tag = backupDeviceTagFromFilename(filename);
  if (tag == null) return BackupOwnership.unattributed;
  if (thisDeviceId.isEmpty) return BackupOwnership.unattributed;
  return tag == deviceTag(thisDeviceId)
      ? BackupOwnership.thisDevice
      : BackupOwnership.otherDevice;
}
