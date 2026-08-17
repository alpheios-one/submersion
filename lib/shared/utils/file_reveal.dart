import 'dart:io';

/// Whether this platform can reveal a file in a native file manager.
///
/// Mobile has no equivalent: there is no user-visible filesystem to reveal
/// a path in, so callers hide the affordance rather than offering one that
/// does nothing.
bool get canRevealInFileManager =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// Reveals [path] in the platform's native file manager.
///
/// Failures of the spawned process are intentionally swallowed: surfacing
/// them would require UX out of scope for what is a convenience affordance,
/// and the common failure (the file moved since the panel read the row) is
/// already what the caller is looking at.
Future<void> revealInFileManager(String path) async {
  if (!canRevealInFileManager) return;
  // coverage:ignore-start
  // Shells out to Process.run, which flutter_test cannot exercise. Covered
  // by manual desktop smoke tests; the platform predicate above is what is
  // unit-tested.
  try {
    if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else if (Platform.isWindows) {
      await Process.run('explorer', ['/select,', path]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [File(path).parent.path]);
    }
  } on ProcessException {
    // The doc above promises failures are swallowed, and Process.run throws
    // rather than returning non-zero when the executable is absent, which is
    // routine on a minimal Linux desktop with no xdg-open.
  }
  // coverage:ignore-end
}
