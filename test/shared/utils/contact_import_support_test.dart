import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/shared/utils/contact_import_support.dart';

void main() {
  test('contacts are supported only on iOS and Android', () {
    // flutter_contacts ships iOS and Android implementations only. This guard
    // was lifted out of buddy_list_content's private getter so the import flow
    // and the profile photo source sheet cannot drift apart on which
    // platforms offer contacts.
    final expected = !kIsWeb && (Platform.isIOS || Platform.isAndroid);
    expect(isContactImportSupported, expected);
  });

  test('the guard is false on the desktop host running these tests', () {
    // The suite runs on macOS/Linux/Windows in CI, never on a mobile target,
    // so the guard must report false here. If this ever fails, the platform
    // detection has broken rather than the expectation.
    if (Platform.isIOS || Platform.isAndroid) {
      return;
    }
    expect(isContactImportSupported, isFalse);
  });
}
