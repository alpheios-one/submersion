import 'package:equatable/equatable.dart';

/// One provenance row's stretch of a dive's timeline, in seconds from the
/// dive's start.
class SourceSpan extends Equatable {
  const SourceSpan({
    required this.sourceId,
    required this.start,
    required this.end,
  });

  final String sourceId;
  final int start;
  final int end;

  @override
  List<Object?> get props => [sourceId, start, end];
}

/// Groups a dive's `dive_data_sources` rows into the segments a Combine
/// stitched together (issue #1504).
///
/// Two rows belong to the same segment when their spans overlap: that is two
/// computers recording the same minutes, which is a consolidation, not a
/// combine. Rows whose spans are disjoint are consecutive segments of one
/// stitched timeline. This is the same test `sourceProfilesAreSequential`
/// applies to decide how the chart renders a dive, applied to the raw rows
/// rather than the canonicalized ones, so the two cannot disagree about what
/// a combined dive is.
///
/// Spans that merely touch count as disjoint, matching that function: a
/// Combine's synthesized surface fill is appended to the segment before the
/// gap, so the next segment starts exactly where the previous one ended.
///
/// Returns segments in timeline order. Within a segment the ids keep the
/// order [spans] was given in, so a caller that hands rows over in canonical
/// order (primary first, then oldest) gets each segment's lead row first.
///
/// [spanless] rows carry no timeline of their own (no samples and no
/// entry/exit times), so nothing can place them; they join the first
/// segment, which is the one that stays behind on the original dive. A dive
/// with fewer than two segments was not combined, and the result is a single
/// segment holding every id.
List<List<String>> groupSourcesIntoSegments({
  required List<SourceSpan> spans,
  List<String> spanless = const [],
}) {
  if (spans.isEmpty) {
    return spanless.isEmpty ? const [] : [List<String>.of(spanless)];
  }

  final givenOrder = {
    for (var i = 0; i < spans.length; i++) spans[i].sourceId: i,
  };
  final ordered = [...spans]
    ..sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      if (byStart != 0) return byStart;
      final byEnd = a.end.compareTo(b.end);
      return byEnd != 0
          ? byEnd
          : givenOrder[a.sourceId]!.compareTo(givenOrder[b.sourceId]!);
    });

  final segments = <List<String>>[];
  var current = <String>[ordered.first.sourceId];
  // The furthest end seen inside the current segment, not just the previous
  // span's: a span nested inside an earlier one starts later but overlaps it.
  var reach = ordered.first.end;
  for (final span in ordered.skip(1)) {
    if (span.start < reach) {
      current.add(span.sourceId);
      if (span.end > reach) reach = span.end;
    } else {
      segments.add(current);
      current = <String>[span.sourceId];
      reach = span.end;
    }
  }
  segments.add(current);

  for (final segment in segments) {
    segment.sort((a, b) => givenOrder[a]!.compareTo(givenOrder[b]!));
  }
  if (spanless.isNotEmpty) segments.first.addAll(spanless);
  return segments;
}
