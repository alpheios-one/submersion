import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_log/domain/entities/source_profile.dart';

SourceProfile _source(String id, List<int> timestamps) => SourceProfile(
  sourceId: id,
  computerId: null,
  isEdited: false,
  points: [
    for (final t in timestamps) DiveProfilePoint(timestamp: t, depth: 10),
  ],
);

void main() {
  group('sourceProfilesAreSequential', () {
    test('is false for a single source', () {
      expect(
        sourceProfilesAreSequential([
          _source('a', [0, 60, 120]),
        ]),
        isFalse,
      );
    });

    test('is false when no source has samples', () {
      expect(
        sourceProfilesAreSequential([_source('a', []), _source('b', [])]),
        isFalse,
      );
    });

    test('is false when two computers cover the same minutes', () {
      expect(
        sourceProfilesAreSequential([
          _source('a', [0, 600, 1200]),
          _source('b', [10, 610, 1190]),
        ]),
        isFalse,
      );
    });

    test('is false when one span is nested inside another', () {
      // Guards the running-max: sorted by start, the nested span begins
      // after the previous one but still overlaps it.
      expect(
        sourceProfilesAreSequential([
          _source('a', [0, 3600]),
          _source('b', [600, 1200]),
          _source('c', [900, 1000]),
        ]),
        isFalse,
      );
    });

    test('is true for the halves of a combined dive', () {
      expect(
        sourceProfilesAreSequential([
          _source('first', [0, 600, 1200]),
          _source('second', [1500, 2100, 2700]),
        ]),
        isTrue,
      );
    });

    test('is true when the halves touch at the boundary', () {
      // A Combine appends its synthesized surface fill to the segment before
      // the gap, so the next segment can start exactly where it ended.
      expect(
        sourceProfilesAreSequential([
          _source('first', [0, 600, 1200]),
          _source('second', [1200, 1800]),
        ]),
        isTrue,
      );
    });

    test('ignores a metadata-only source with no samples', () {
      expect(
        sourceProfilesAreSequential([
          _source('first', [0, 600]),
          _source('metadata-only', []),
          _source('second', [900, 1500]),
        ]),
        isTrue,
      );
    });

    test('reads each span as min and max, not first and last', () {
      // mergeSeriesPoints returns a lone series' samples untouched, so a
      // source that owns one series can hand over points in any order. Taking
      // the ends off the list would read the second source's span as
      // (2100, 1500), an inverted interval that overlaps the first.
      expect(
        sourceProfilesAreSequential([
          _source('first', [600, 0, 1200]),
          _source('second', [2100, 2700, 1500]),
        ]),
        isTrue,
      );
      // The mirror case: genuinely overlapping sources stay overlapping when
      // their points arrive out of order.
      expect(
        sourceProfilesAreSequential([
          _source('a', [1200, 0, 600]),
          _source('b', [1190, 10, 610]),
        ]),
        isFalse,
      );
    });

    test('answers on argument order, not iteration order', () {
      expect(
        sourceProfilesAreSequential([
          _source('second', [1500, 2100]),
          _source('first', [0, 600]),
        ]),
        isTrue,
      );
    });
  });
}
