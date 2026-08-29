import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_sample.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_series_summary.dart';
import 'package:submersion/features/dive_log/domain/entities/profile_series.dart';
import 'package:submersion/features/dive_log/domain/services/profile_series_merge.dart';

ProfileSeries series(
  String id, {
  String? computerId,
  String? sourceId,
  bool isPrimary = true,
  required List<ProfileSample> samples,
}) => ProfileSeries(
  id: id,
  diveId: 'd1',
  computerId: computerId,
  sourceId: sourceId,
  isPrimary: isPrimary,
  summary: ProfileSeriesSummary.of(samples),
  samples: samples,
  codecVersion: 1,
  createdAt: 0,
  updatedAt: 0,
);

void main() {
  group('mergeSeriesPoints', () {
    test('a single series maps straight to points', () {
      final s = series(
        'a',
        samples: const [
          ProfileSample(timestamp: 0, depth: 0.0),
          ProfileSample(timestamp: 10, depth: 5.0),
        ],
      );
      expect(mergeSeriesPoints([s]).map((p) => p.timestamp), [0, 10]);
    });

    test('two series interleave by timestamp', () {
      final a = series(
        'a',
        computerId: 'c1',
        samples: const [
          ProfileSample(timestamp: 0, depth: 0.0),
          ProfileSample(timestamp: 20, depth: 10.0),
        ],
      );
      final b = series(
        'b',
        computerId: 'c2',
        samples: const [
          ProfileSample(timestamp: 10, depth: 4.0),
          ProfileSample(timestamp: 30, depth: 2.0),
        ],
      );
      expect(mergeSeriesPoints([a, b]).map((p) => p.timestamp), [
        0,
        10,
        20,
        30,
      ]);
    });

    test('ties keep series order, then within-series order', () {
      final a = series(
        'a',
        samples: const [
          ProfileSample(timestamp: 10, depth: 1.0),
          ProfileSample(timestamp: 10, depth: 1.5),
        ],
      );
      final b = series(
        'b',
        samples: const [ProfileSample(timestamp: 10, depth: 2.0)],
      );
      expect(mergeSeriesPoints([a, b]).map((p) => p.depth), [1.0, 1.5, 2.0]);
      expect(mergeSeriesPoints([b, a]).map((p) => p.depth), [2.0, 1.0, 1.5]);
    });

    test('an empty list merges to an empty list', () {
      expect(mergeSeriesPoints(const []), isEmpty);
    });
  });

  group('dropSupersededSeries', () {
    final original = series(
      'orig',
      computerId: 'c1',
      sourceId: 's1',
      isPrimary: false,
      samples: const [ProfileSample(timestamp: 0, depth: 1.0)],
    );
    final edit = series(
      'edit',
      sourceId: 's1',
      samples: const [ProfileSample(timestamp: 0, depth: 2.0)],
    );
    final other = series(
      'other',
      computerId: 'c2',
      sourceId: 's2',
      isPrimary: false,
      samples: const [ProfileSample(timestamp: 0, depth: 3.0)],
    );

    test('an edit drops the demoted original of the primary family', () {
      final kept = dropSupersededSeries(
        [original, edit, other],
        hasSources: true,
        primaryComputerId: 'c1',
      );
      expect(kept.map((s) => s.id), ['edit', 'other']);
    });

    test('without an edit nothing is dropped', () {
      final kept = dropSupersededSeries(
        [original, other],
        hasSources: true,
        primaryComputerId: 'c1',
      );
      expect(kept.map((s) => s.id), ['orig', 'other']);
    });

    test('a dive with no primary series keeps everything', () {
      final kept = dropSupersededSeries(
        [original, other],
        hasSources: true,
        primaryComputerId: null,
      );
      expect(kept, hasLength(2));
    });

    test('with no data sources every series is family', () {
      final demotedManual = series(
        'old',
        isPrimary: false,
        samples: const [ProfileSample(timestamp: 0, depth: 1.0)],
      );
      final kept = dropSupersededSeries(
        [demotedManual, edit, other],
        hasSources: false,
        primaryComputerId: null,
      );
      expect(kept.map((s) => s.id), ['edit']);
    });
  });
}
