import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/features/dive_log/data/services/merge_gap_fill.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_sample.dart';

DiveProfileEvent _event({
  required String id,
  required int timestamp,
  String eventType = 'surface',
  String source = 'app',
}) => DiveProfileEvent(
  id: id,
  diveId: 'dive-1',
  timestamp: timestamp,
  eventType: eventType,
  severity: 'info',
  source: source,
  createdAt: 0,
);

void main() {
  group('readFrom', () {
    test('pairs the surface markers a merge writes', () {
      final gaps = MergeGapFill.readFrom([
        _event(id: 'g1e', timestamp: 3600),
        _event(id: 'g1s', timestamp: 1800),
      ]);

      expect(gaps.isNotEmpty, isTrue);
      expect(gaps.clampEnd(3000), 1800);
      expect(gaps.clampStart(3000), 3600);
    });

    test('ignores imported surface events', () {
      // Only the merge writes them with source 'app'; an importer's own
      // surface event marks no gap.
      final gaps = MergeGapFill.readFrom([
        _event(id: 'a', timestamp: 1800, source: 'imported'),
        _event(id: 'b', timestamp: 3600, source: 'imported'),
      ]);

      expect(gaps.isNotEmpty, isFalse);
    });

    test('ignores non-surface app events', () {
      final gaps = MergeGapFill.readFrom([
        _event(id: 'a', timestamp: 1800, eventType: 'gaschange'),
        _event(id: 'b', timestamp: 3600, eventType: 'gaschange'),
      ]);

      expect(gaps.isNotEmpty, isFalse);
    });

    test('leaves an odd trailing marker naming no gap', () {
      final gaps = MergeGapFill.readFrom([
        _event(id: 'a', timestamp: 1800),
        _event(id: 'b', timestamp: 3600),
        _event(id: 'c', timestamp: 7200),
      ]);

      expect(gaps.isMarker(_event(id: 'a', timestamp: 1800)), isTrue);
      expect(gaps.isMarker(_event(id: 'c', timestamp: 7200)), isFalse);
    });
  });

  group('trim', () {
    test('drops only the samples strictly inside a gap', () {
      const gaps = MergeGapFill.forBounds([(1800, 3600)]);
      final samples = [
        for (final t in [0, 900, 1800, 1801, 2700, 3599, 3600, 4200])
          ProfileSample(timestamp: t, depth: 10),
      ];

      expect(
        gaps.trim(samples).map((p) => p.timestamp),
        // The boundaries themselves are the two segments' own last and first
        // samples, not fill.
        [0, 900, 1800, 3600, 4200],
      );
    });

    test('leaves everything alone when there are no gaps', () {
      const gaps = MergeGapFill.forBounds([]);
      final samples = [
        for (final t in [0, 900, 1800]) ProfileSample(timestamp: t, depth: 10),
      ];

      expect(gaps.trim(samples), hasLength(3));
    });
  });

  group('clamping', () {
    test('a timestamp outside every gap is unchanged', () {
      const gaps = MergeGapFill.forBounds([(1800, 3600)]);

      expect(gaps.clampStart(900), 900);
      expect(gaps.clampEnd(900), 900);
      expect(gaps.clampStart(1800), 1800);
      expect(gaps.clampEnd(3600), 3600);
    });

    test('a series wholly inside a gap clamps to an empty span', () {
      const gaps = MergeGapFill.forBounds([(1800, 3600)]);

      expect(gaps.clampStart(2000) > gaps.clampEnd(3000), isTrue);
    });
  });

  group('confineEnd', () {
    test('pulls an end back to the first gap after the start', () {
      // The shape a combine of a combine writes: the first segment's primary
      // series carries the fill for BOTH gaps, so clamping its end lands on
      // the second gap's start rather than on its own last real sample.
      const gaps = MergeGapFill.forBounds([(1800, 3600), (4800, 7200)]);

      expect(gaps.clampEnd(7199), 4800);
      expect(gaps.confineEnd(0, gaps.clampEnd(7199)), 1800);
    });

    test('leaves a span that reaches no gap alone', () {
      const gaps = MergeGapFill.forBounds([(1800, 3600)]);

      expect(gaps.confineEnd(3600, 4800), 4800);
    });

    test('is a no-op without gaps', () {
      const gaps = MergeGapFill.forBounds([]);

      expect(gaps.confineEnd(0, 4800), 4800);
    });
  });
}
