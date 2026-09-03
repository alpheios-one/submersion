import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/services/sync/changeset_log/base_apply_progress.dart';

void main() {
  List<double> drive(void Function(BaseApplyProgress p) script) {
    final seen = <double>[];
    final p = BaseApplyProgress(1000, seen.add);
    script(p);
    return seen;
  }

  test('maps three passes onto thirds and ends at 1.0', () {
    final seen = drive((p) {
      p.bytes(500, 1000);
      p.bytes(1000, 1000);
      p.beginPass(1);
      p.bytes(1000, 1000);
      p.beginPass(2);
      p.bytes(300, 1000);
      p.done();
    });
    expect(seen.first, closeTo(1 / 6, 1e-9));
    expect(seen.last, 1.0);
    expect(
      seen,
      containsAllInOrder([closeTo(1 / 3, 1e-9), closeTo(2 / 3, 1e-9)]),
    );
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
    }
  });

  test('the inline path reports through consumed bytes against the total', () {
    final seen = drive((p) => p.consumed(250));
    expect(seen, [closeTo(0.25 / 3, 1e-9)]);
  });

  test('a restart after a mid-apply worker failure keeps every inline pass '
      'visible, never rewinds, and still ends at 1.0', () {
    // Worker dies three quarters into pass 3, then the inline fallback runs
    // all three passes over the same file (issue #1421 review finding).
    final seen = drive((p) {
      p.bytes(1000, 1000);
      p.beginPass(1);
      p.bytes(1000, 1000);
      p.beginPass(2);
      p.bytes(750, 1000);
      p.restart();
      p.consumed(500);
      p.consumed(1000);
      p.beginPass(1);
      p.consumed(500);
      p.consumed(1000);
      p.beginPass(2);
      p.consumed(500);
      p.done();
    });
    // Five ticks precede the restart (a pass boundary may repeat a value).
    const preRestart = 5;
    for (var i = 1; i < preRestart; i++) {
      expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
    }
    expect(seen[preRestart - 1], closeTo(2.75 / 3, 1e-9));
    // Every inline tick must land above the worker's high-water mark and
    // keep climbing: a stale pass index would park the bar at 100% here.
    final inline = seen.sublist(preRestart);
    expect(inline.first, greaterThan(seen[preRestart - 1]));
    for (var i = 1; i < inline.length; i++) {
      expect(inline[i], greaterThanOrEqualTo(inline[i - 1]));
    }
    // Seven inline reports, two of them pass-boundary repeats: five distinct
    // climbing values below 1.0, then the final 1.0.
    expect(inline.toSet().length, 6);
    expect(seen.last, 1.0);
    // Every inline tick before done() must stay strictly below 1.0 so the
    // bar keeps moving through the fallback instead of parking at 100%.
    for (final v in seen.sublist(0, seen.length - 1)) {
      expect(v, lessThan(1.0));
    }
  });
}
