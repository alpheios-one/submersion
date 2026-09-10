import 'package:submersion/core/database/database.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_sample.dart';

/// The gaps a Combine bridged with synthesized surface samples, read back off
/// the `surface` events it wrote at each gap's boundaries.
///
/// Those markers are the only durable record of where the gaps were, and they
/// are identifiable: `DiveMergeService.apply` writes them in pairs with
/// `eventType` `surface` and `source` `app`, which no importer does. The fill
/// itself runs strictly between each pair, so the boundary samples are real
/// data and survive every operation here.
///
/// Used by [DiveUncombineService] both to measure where each segment really
/// sits on the combined timeline and to drop the fill once the gaps it
/// bridged are gone.
class MergeGapFill {
  const MergeGapFill._(this._bounds, this._markerIds);

  /// Reads the gaps out of one dive's profile events.
  factory MergeGapFill.readFrom(List<DiveProfileEvent> events) {
    final markers =
        events
            .where((e) => e.eventType == 'surface' && e.source == 'app')
            .toList()
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    // Pairs, in the order the merge wrote them: gap start then gap end. An
    // odd trailing marker names no gap and is left alone.
    final bounds = <(int, int)>[];
    final ids = <String>{};
    for (var i = 0; i + 1 < markers.length; i += 2) {
      bounds.add((markers[i].timestamp, markers[i + 1].timestamp));
      ids.addAll([markers[i].id, markers[i + 1].id]);
    }
    return MergeGapFill._(bounds, ids);
  }

  /// The gaps directly, for tests and for callers that already know them.
  const MergeGapFill.forBounds(List<(int, int)> bounds)
    : _bounds = bounds,
      _markerIds = const {};

  final List<(int, int)> _bounds;
  final Set<String> _markerIds;

  bool get isNotEmpty => _bounds.isNotEmpty;

  /// [samples] with the synthesized surface fill removed.
  List<ProfileSample> trim(List<ProfileSample> samples) => [
    for (final sample in samples)
      if (!_inside(sample.timestamp)) sample,
  ];

  /// Whether [event] is one of the markers bracketing a gap.
  bool isMarker(DiveProfileEvent event) => _markerIds.contains(event.id);

  /// [timestamp] moved forward out of any gap it starts inside, to where the
  /// next segment begins. The summary-column equivalent of what [trim] does
  /// to a series' first sample.
  int clampStart(int timestamp) {
    for (final bound in _bounds) {
      if (_within(timestamp, bound)) return bound.$2;
    }
    return timestamp;
  }

  /// [timestamp] moved back out of any gap it ends inside, to where the
  /// previous segment's own last sample sits. Exact for what a merge writes:
  /// the fill starts one second past that sample.
  int clampEnd(int timestamp) {
    for (final bound in _bounds) {
      if (_within(timestamp, bound)) return bound.$1;
    }
    return timestamp;
  }

  /// [end] pulled back to the first gap that opens at or after [start], so a
  /// span cannot reach past the segment its samples begin in.
  ///
  /// [clampEnd] alone is not enough. The merge appends a gap's fill to its
  /// segment's PRIMARY series rather than to whichever one is adjacent in
  /// time, so on a combine of a combine one series carries the fill for a gap
  /// its own samples end nowhere near, and clamping lands it on the wrong
  /// boundary. A span's start is never in doubt, because the fill is only
  /// ever appended.
  int confineEnd(int start, int end) {
    var confined = end;
    for (final bound in _bounds) {
      if (bound.$1 >= start && bound.$1 < confined) confined = bound.$1;
    }
    return confined;
  }

  bool _inside(int timestamp) =>
      _bounds.any((bound) => _within(timestamp, bound));

  static bool _within(int timestamp, (int, int) bound) =>
      timestamp > bound.$1 && timestamp < bound.$2;
}
