import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/shared/utils/file_reveal.dart';

void main() {
  test('reveal is offered on desktop only', () {
    final expected = Platform.isMacOS || Platform.isWindows || Platform.isLinux;

    expect(canRevealInFileManager, expected);
  });

  // Named for what is actually exercised. On a desktop host this DOES shell
  // out, so the old name ("no-op on an unsupported platform") described a
  // branch the test never took and implied coverage it did not have.
  test('revealing a path that does not exist does not throw', () async {
    await expectLater(
      revealInFileManager('/definitely/not/a/real/path/reef.jpg'),
      completes,
    );
  });
}
