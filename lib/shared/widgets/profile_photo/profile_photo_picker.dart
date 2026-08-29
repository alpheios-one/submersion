import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:submersion/shared/widgets/profile_photo/profile_photo_crop_dialog.dart';
import 'package:submersion/shared/widgets/profile_photo/profile_photo_source_sheet.dart';

/// Outcome of running the profile photo flow.
///
/// [removed] distinguishes "the user asked to delete the photo" from "the user
/// cancelled", which a bare `Uint8List?` cannot express.
@immutable
class ProfilePhotoResult {
  const ProfilePhotoResult({this.bytes, this.removed = false});

  final Uint8List? bytes;
  final bool removed;
}

/// Runs the whole flow: source sheet, byte acquisition, crop dialog, encode.
///
/// Returns null if the user cancelled at any point.
///
/// Size bounding happens in the crop dialog's encode step, never through
/// ImagePicker's maxWidth / maxHeight / imageQuality: image_picker_macos,
/// image_picker_windows and image_picker_linux all document that those
/// arguments are silently ignored, so a desktop pick would be unbounded.
///
/// [contactPhotoLoader] is supplied by callers that can reach the address
/// book, which keeps this shared widget free of a flutter_contacts dependency.
Future<ProfilePhotoResult?> pickProfilePhoto({
  required BuildContext context,
  required bool hasPhoto,
  required bool allowContacts,
  Future<Uint8List?> Function(BuildContext context)? contactPhotoLoader,
}) async {
  // Offering Contacts without a loader would show a menu item that silently
  // does nothing when tapped, which reads as a broken flow. The two are
  // therefore gated together rather than independently.
  final source = await showProfilePhotoSourceSheet(
    context: context,
    hasPhoto: hasPhoto,
    allowContacts: allowContacts && contactPhotoLoader != null,
  );
  if (source == null || !context.mounted) return null;

  if (source == ProfilePhotoSource.remove) {
    return const ProfilePhotoResult(removed: true);
  }

  Uint8List? raw;
  String? declaredName;

  if (source == ProfilePhotoSource.contacts) {
    // Unreachable without a loader, since the option is gated above.
    raw = await contactPhotoLoader!(context);
    declaredName = 'contact.jpg';
    if (raw == null) return null;
  } else {
    final picked = await ImagePicker().pickImage(
      source: source == ProfilePhotoSource.camera
          ? ImageSource.camera
          : ImageSource.gallery,
    );
    if (picked == null) return null;
    raw = await File(picked.path).readAsBytes();
    declaredName = picked.name;
  }

  if (!context.mounted) return null;

  final encoded = await showProfilePhotoCropDialog(
    context: context,
    sourceBytes: raw,
    declaredName: declaredName,
  );
  if (encoded == null) return null;
  return ProfilePhotoResult(bytes: encoded);
}
