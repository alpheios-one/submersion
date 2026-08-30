import 'dart:typed_data';

import 'package:submersion/core/deco/ascent_rate_calculator.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_sample.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_series_codec.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_series_codec_exception.dart';

/// Smoothing interval used by [ascentDescentRates], in seconds.
///
/// Kept in sync with the per-dive calculator's configured target interval so
/// the two cannot drift apart on how much of a profile they smooth over. The
/// filters themselves differ: [AscentRateCalculator] takes an overlapping,
/// centred moving average over point-to-point rates (window rounded to an odd
/// count of samples, minimum three), while this aggregate averages depth into
/// fixed non-overlapping buckets and differences consecutive bucket means.
/// Both suppress the same short-timescale noise; neither is a reimplementation
/// of the other, and their per-profile outputs are close but not identical.
const int rateWindowSeconds =
    AscentRateCalculator.defaultSmoothingWindowSeconds;

/// Slowest vertical rate that counts as ascending or descending rather than
/// working a multi-level profile, in m/min.
///
/// A recreational profile spends most of its windows drifting slowly around
/// the bottom: on a representative library, windows in the 0.5-3 m/min band
/// outnumber genuine transit roughly four to one. Averaging those in drags
/// both figures down to around 2.4 m/min, which tells a diver nothing and is
/// not comparable to the ascent-rate limits they are trained against. Only
/// counting sustained movement keeps the card answering "how fast do I
/// actually go up and down".
const double sustainedTransitThreshold = 3.0;

/// How many times its own mean sample interval a profile may skip before
/// [timeAtDepthRanges] stops crediting the skip as time at that depth.
///
/// Recording gaps are real: a computer paused mid-dive, a surface interval
/// swallowed into one dive record, a profile stitched from two downloads.
/// Charging the whole pause to whichever bucket the last sample before it
/// happened to sit in would invent hours of bottom time. The bound is
/// relative to the profile's own cadence rather than an absolute number of
/// seconds because recording intervals in a real library run from 1 s to a
/// minute or more, and a manually keyed profile is sparser still. Four times
/// the mean leaves room for ordinary jitter and the occasional dropped
/// sample while cutting anything an order of magnitude larger down to size.
const int maxSampleGapFactor = 4;

typedef StreamKey = (String diveId, String? computerId);
typedef DepthBucket = ({int lowerDepth, int? upperDepth, int minutes});

/// One primary series as it crosses the isolate boundary: identity plus the
/// undecoded blob. Decoding happens on the worker.
class SeriesBlob {
  const SeriesBlob({
    required this.diveId,
    required this.computerId,
    required this.samples,
  });
  final String diveId;
  final String? computerId;
  final Uint8List samples;
}

/// One corrupt local blob (a decode failure the writer never should have let
/// through, but storage can still bit-rot) is skipped rather than failing
/// the whole aggregate: every other blob's samples still contribute, so one
/// bad row blanks only its own stream instead of every chart on the dive.
Map<StreamKey, List<ProfileSample>> _decodeStreams(List<SeriesBlob> blobs) {
  const codec = ProfileSeriesCodec();
  final streams = <StreamKey, List<ProfileSample>>{};
  for (final b in blobs) {
    final List<ProfileSample> decoded;
    try {
      decoded = codec.decode(b.samples);
    } on ProfileSeriesCodecException {
      continue;
    }
    streams.update(
      (b.diveId, b.computerId),
      (existing) => _mergedByTimestamp(existing, decoded),
      ifAbsent: () => decoded,
    );
  }
  return streams;
}

/// Stable interleave of two timestamp-ordered lists (two series of one
/// stream, in stored order for a timestamp tie).
///
/// "Stored order" here is `ProfileSeriesRepository.getRowsForDives`'s
/// `(diveId, startTimestamp, id)` ordering: [a] and [b] arrive from that
/// query already sorted, so a tie always breaks on series id rather than on
/// insertion order or scan order, which is what makes the merged result the
/// same on every device regardless of which one produced it.
List<ProfileSample> _mergedByTimestamp(
  List<ProfileSample> a,
  List<ProfileSample> b,
) {
  final out = <ProfileSample>[];
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    if (b[j].timestamp < a[i].timestamp) {
      out.add(b[j++]);
    } else {
      out.add(a[i++]);
    }
  }
  out.addAll(a.sublist(i));
  out.addAll(b.sublist(j));
  return out;
}

({double? avgAscent, double? avgDescent}) ascentDescentRatesFromBlobs(
  List<SeriesBlob> blobs,
) => ascentDescentRates(_decodeStreams(blobs));

List<DepthBucket> timeAtDepthRangesFromBlobs(List<SeriesBlob> blobs) =>
    timeAtDepthRanges(_decodeStreams(blobs));

/// The legacy SQL, in Dart: per stream, samples fall into windows of
/// [rateWindowSeconds] by `timestamp ~/ rateWindowSeconds`; each window
/// contributes its mean depth and mean timestamp; consecutive windows (in
/// window order) give `rate = (prevDepth - depth) * 60 / (at - prevAt)` when
/// `at > prevAt`; ascents average the rates at or above the threshold,
/// descents the rates at or below its negative (negated).
///
/// Assumes each stream's samples are already sorted by timestamp.
({double? avgAscent, double? avgDescent}) ascentDescentRates(
  Map<StreamKey, List<ProfileSample>> samplesByStream,
) {
  final ascents = <double>[];
  final descents = <double>[];
  for (final samples in samplesByStream.values) {
    final windows = <int, ({double depthSum, double atSum, int n})>{};
    for (final s in samples) {
      final index = s.timestamp ~/ rateWindowSeconds;
      final w = windows[index];
      windows[index] = w == null
          ? (depthSum: s.depth, atSum: s.timestamp.toDouble(), n: 1)
          : (
              depthSum: w.depthSum + s.depth,
              atSum: w.atSum + s.timestamp,
              n: w.n + 1,
            );
    }
    final ordered = windows.keys.toList()..sort();
    double? prevDepth;
    double? prevAt;
    for (final index in ordered) {
      final w = windows[index]!;
      final depth = w.depthSum / w.n;
      final at = w.atSum / w.n;
      if (prevAt != null && at > prevAt) {
        final rate = (prevDepth! - depth) * 60.0 / (at - prevAt);
        if (rate >= sustainedTransitThreshold) ascents.add(rate);
        if (rate <= -sustainedTransitThreshold) descents.add(-rate);
      }
      prevDepth = depth;
      prevAt = at;
    }
  }
  double? mean(List<double> xs) =>
      xs.isEmpty ? null : xs.reduce((a, b) => a + b) / xs.length;
  return (avgAscent: mean(ascents), avgDescent: mean(descents));
}

/// The legacy SQL, in Dart: per stream with more than one sample, the cadence
/// cap is `(maxAt - minAt) * maxSampleGapFactor / (n - 1)`; each interval to
/// the next sample (in stored order after the timestamp sort) is bucketed by
/// its start depth (`< 10` -> 0, `< 20` -> 10, `< 30` -> 20, `< 40` -> 30,
/// else 40) and contributes `min(seconds, cap)` when `seconds > 0`. Buckets
/// come back ascending; empty buckets are absent.
///
/// Assumes each stream's samples are already sorted by timestamp, with ties
/// in stored order.
List<DepthBucket> timeAtDepthRanges(
  Map<StreamKey, List<ProfileSample>> samplesByStream,
) {
  final seconds = <int, double>{};
  for (final samples in samplesByStream.values) {
    if (samples.length < 2) continue;
    final minAt = samples.first.timestamp;
    final maxAt = samples.last.timestamp;
    final cap = (maxAt - minAt) * maxSampleGapFactor / (samples.length - 1.0);
    for (var i = 0; i + 1 < samples.length; i++) {
      final gap = samples[i + 1].timestamp - samples[i].timestamp;
      if (gap <= 0) continue;
      final lo = _bucketLo(samples[i].depth);
      seconds[lo] = (seconds[lo] ?? 0) + (gap < cap ? gap.toDouble() : cap);
    }
  }
  final los = seconds.keys.toList()..sort();
  return [
    for (final lo in los)
      (
        lowerDepth: lo,
        upperDepth: lo >= 40 ? null : lo + 10,
        minutes: (seconds[lo]! / 60).round(),
      ),
  ];
}

int _bucketLo(double depth) {
  if (depth < 10) return 0;
  if (depth < 20) return 10;
  if (depth < 30) return 20;
  if (depth < 40) return 30;
  return 40;
}
