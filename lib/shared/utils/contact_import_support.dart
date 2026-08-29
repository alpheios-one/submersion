import 'dart:io';

import 'package:flutter/foundation.dart';

/// Whether the device address book can be reached at all.
///
/// flutter_contacts ships iOS and Android implementations only. Lifted out of
/// `buddy_list_content.dart` so the buddy import flow and the profile photo
/// source sheet cannot drift apart on which platforms they offer contacts on.
bool get isContactImportSupported {
  if (kIsWeb) return false;
  return Platform.isIOS || Platform.isAndroid;
}
