import 'package:submersion/features/dive_log/domain/entities/dive.dart';

/// One data source's profile samples for a dive, keyed by the
/// dive_data_sources row that owns them.
class SourceProfile {
  const SourceProfile({
    required this.sourceId,
    required this.computerId,
    required this.isEdited,
    required this.points,
  });

  final String sourceId;
  final String? computerId;

  /// True when these are user-edited rows replacing the primary source's
  /// original samples.
  final bool isEdited;
  final List<DiveProfilePoint> points;
}

/// True when [profiles] read as consecutive segments of one timeline rather
/// than competing recordings of the same minutes (issue #1451).
///
/// A dive gets per-source rendering -- one drawn series with the rest
/// available as overlays -- because two computers recording the same dive
/// disagree sample by sample, and interleaving them draws a sawtooth
/// (issue #543). That reasoning does not hold for the halves of a dive a
/// computer split in two and a Combine stitched back together: each half owns
/// its own stretch of the timeline, so drawing one means hiding the rest of
/// the dive. Those are told apart by whether the sources overlap in time, not
/// by counting them.
///
/// Sources with no samples carry no span and are ignored; fewer than two
/// spans is not a sequential arrangement, so the answer is false and callers
/// keep whatever they do for an ordinary dive. Spans that merely touch at a
/// boundary count as disjoint: a Combine's synthesized surface fill is
/// appended to the segment before the gap, so the next segment starts exactly
/// where it ended.
bool sourceProfilesAreSequential(Iterable<SourceProfile> profiles) {
  final spans = <(int, int)>[
    for (final p in profiles)
      if (p.points.isNotEmpty)
        (p.points.first.timestamp, p.points.last.timestamp),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  if (spans.length < 2) return false;
  // Compared against the furthest end seen so far, not just the previous
  // span's: a span nested inside an earlier one starts later but overlaps it.
  var reach = spans.first.$2;
  for (final (start, end) in spans.skip(1)) {
    if (start < reach) return false;
    if (end > reach) reach = end;
  }
  return true;
}
