import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_log/domain/entities/dive_data_source.dart';

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
///
/// Each span is the min and max of its points rather than the first and last.
/// Sorted order is not an invariant of [SourceProfile.points]: mergeSeriesPoints
/// sorts only when it has two or more series to interleave and returns a lone
/// series' samples untouched, which is exactly the shape a source owning one
/// series has. Reading the ends off an unsorted list would misjudge the span
/// and pick the wrong rendering mode.
bool sourceProfilesAreSequential(Iterable<SourceProfile> profiles) {
  final spans = <(int, int)>[];
  for (final profile in profiles) {
    if (profile.points.isEmpty) continue;
    var start = profile.points.first.timestamp;
    var end = start;
    for (final point in profile.points) {
      if (point.timestamp < start) start = point.timestamp;
      if (point.timestamp > end) end = point.timestamp;
    }
    spans.add((start, end));
  }
  spans.sort((a, b) => a.$1.compareTo(b.$1));
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

/// Whether a dive's chart draws one source at a time, with the others
/// available as overlays, rather than the whole merged profile (issue #1451).
///
/// Two or more sources is a necessary condition but not a sufficient one: the
/// halves of a dive a Combine stitched together arrive as several sources that
/// never overlap in time, and drawing one of those hides the rest of the dive.
/// Shared by every surface that renders a profile so the three of them cannot
/// drift apart.
bool usesPerSourceRendering(
  List<DiveDataSource> sources,
  Iterable<SourceProfile> profiles,
) => sources.length >= 2 && !sourceProfilesAreSequential(profiles);
