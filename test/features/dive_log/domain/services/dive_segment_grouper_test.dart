import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/dive_log/domain/services/dive_segment_grouper.dart';

void main() {
  SourceSpan span(String id, int start, int end) =>
      SourceSpan(sourceId: id, start: start, end: end);

  group('groupSourcesIntoSegments', () {
    test('no rows at all is no segments', () {
      expect(groupSourcesIntoSegments(spans: const []), isEmpty);
    });

    test('a single source is one segment', () {
      expect(groupSourcesIntoSegments(spans: [span('a', 0, 1800)]), [
        ['a'],
      ]);
    });

    test('two overlapping sources are one segment (a consolidation)', () {
      expect(
        groupSourcesIntoSegments(
          spans: [span('a', 0, 3000), span('b', 60, 2940)],
        ),
        [
          ['a', 'b'],
        ],
      );
    });

    test('two disjoint sources are two segments (a combine)', () {
      expect(
        groupSourcesIntoSegments(
          spans: [span('a', 0, 1800), span('b', 2400, 4200)],
        ),
        [
          ['a'],
          ['b'],
        ],
      );
    });

    test('spans that merely touch are still two segments', () {
      // A Combine appends its synthesized surface fill to the segment before
      // the gap, so the next segment starts exactly where the fill ended.
      expect(
        groupSourcesIntoSegments(
          spans: [span('a', 0, 2400), span('b', 2400, 4200)],
        ),
        [
          ['a'],
          ['b'],
        ],
      );
    });

    test('two consolidated computers combined stay two segments', () {
      expect(
        groupSourcesIntoSegments(
          spans: [
            span('a1', 0, 1800),
            span('b1', 3000, 4800),
            span('a2', 10, 1790),
            span('b2', 3010, 4790),
          ],
        ),
        [
          ['a1', 'a2'],
          ['b1', 'b2'],
        ],
      );
    });

    test('a span nested inside an earlier one joins its segment', () {
      // Compared against the furthest end seen so far, not the previous
      // span's end.
      expect(
        groupSourcesIntoSegments(
          spans: [span('wide', 0, 5000), span('inner', 100, 200)],
        ),
        [
          ['wide', 'inner'],
        ],
      );
    });

    test('segments come back in timeline order regardless of input order', () {
      expect(
        groupSourcesIntoSegments(
          spans: [span('late', 3000, 4800), span('early', 0, 1800)],
        ),
        [
          ['early'],
          ['late'],
        ],
      );
    });

    test('ids inside a segment keep the caller order, not the sort order', () {
      // Callers hand rows over canonically (primary first, then oldest) and
      // rely on the lead row of each segment coming back first.
      expect(
        groupSourcesIntoSegments(
          spans: [span('primary', 60, 2940), span('secondary', 0, 3000)],
        ),
        [
          ['primary', 'secondary'],
        ],
      );
    });

    test('spanless rows join the first segment', () {
      expect(
        groupSourcesIntoSegments(
          spans: [span('a', 0, 1800), span('b', 2400, 4200)],
          spanless: ['noSamples'],
        ),
        [
          ['a', 'noSamples'],
          ['b'],
        ],
      );
    });

    test('spanless rows alone are one segment', () {
      expect(groupSourcesIntoSegments(spans: const [], spanless: ['x', 'y']), [
        ['x', 'y'],
      ]);
    });
  });
}
