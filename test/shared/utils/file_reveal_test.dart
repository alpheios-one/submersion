import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/shared/utils/file_reveal.dart';

void main() {
  test('reveal is offered on desktop only', () {
    final expected = Platform.isMacOS || Platform.isWindows || Platform.isLinux;

    expect(canRevealInFileManager, expected);
  });

  test(
    'revealing on an unsupported platform is a no-op, not a throw',
    () async {
      // On a desktop host this does shell out, so point it at a path that
      // certainly does not exist: the helper swallows process failures by
      // design and the assertion is only that nothing escapes.
      await expectLater(
        revealInFileManager('/definitely/not/a/real/path/reef.jpg'),
        completes,
      );
    },
  );
}
