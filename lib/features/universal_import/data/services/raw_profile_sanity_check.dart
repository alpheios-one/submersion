import 'dart:math' as math;

import 'package:libdivecomputer_plugin/libdivecomputer_plugin.dart' as pigeon;

/// Decides whether a speculative libdivecomputer parse produced a dive
/// profile worth keeping.
///
/// Importers that recover raw device bytes from a third-party logbook do not
/// know for certain which parser those bytes belong to: the source app records
/// a display name, not a libdivecomputer descriptor, and the mapping between
/// them is a best guess. A wrong guess does not necessarily fail loudly.
/// libdivecomputer will happily walk bytes in the wrong format and emit a
/// structurally plausible series - the macOS wrapper has even been observed
/// returning success with a zeroed dive - so "the call did not throw" is not
/// evidence the profile is real (issue #1436).
///
/// The checks here are intentionally coarse. Their job is to reject nonsense,
/// not to referee a close call: a rejected dive falls back to exactly the
/// behaviour a dive on an unrecognised computer already has, so a false
/// negative costs a profile that would otherwise be garbage, while a false
/// positive attaches an invented depth series to a real dive.
class RawProfileSanityCheck {
  const RawProfileSanityCheck._();

  /// Deeper than any dive on record (the open-circuit record is ~332 m), so
  /// anything past this is a misread field, not a dive.
  static const maxPlausibleDepthMeters = 350.0;

  /// Long enough for any saturation-adjacent rebreather dive a recreational
  /// logbook will hold.
  static const maxPlausibleDuration = Duration(hours: 24);

  /// Computers occasionally log a slightly negative depth at the surface from
  /// pressure-sensor drift. Anything past this is a sign bit read out of the
  /// wrong field.
  static const _minPlausibleDepthMeters = -3.0;

  /// How far the parsed values may diverge from what the source app recorded
  /// for the same dive before the parse is rejected.
  ///
  /// This is a *gross* tolerance on purpose. A tight one would reject good
  /// parses whenever the source's own scalars are off, and MacDive's are:
  /// it routinely omits its units row, so a whole logbook can be read as feet
  /// when it is metres or the reverse (#912), a 3.28x error that says nothing
  /// about whether the raw bytes decoded correctly. Wrong-format parses miss
  /// by far more than this.
  static const _grossFactor = 5.0;
  static const _depthFloorMeters = 5.0;
  static const _durationFloor = Duration(minutes: 5);

  /// Whether [parsed] should be accepted as this dive's profile.
  ///
  /// [recordedMaxDepthMeters] and [recordedDuration] are the source app's own
  /// values for the same dive, in SI units, or null where it recorded none.
  /// They are used only as a gross cross-check; the hard bounds apply either
  /// way.
  static bool accepts(
    pigeon.ParsedDive parsed, {
    double? recordedMaxDepthMeters,
    Duration? recordedDuration,
  }) {
    // No samples means the parser found no profile at all, whatever else it
    // filled in. This is the failure mode a zeroed dive presents as.
    if (parsed.samples.isEmpty) return false;

    // NaN has to be rejected explicitly rather than left to the bounds below.
    // Every comparison against it is false, so a NaN depth would slip past the
    // lower bound, never become the running maximum, and never trip the upper
    // bound either, arriving in the profile as a sample depth of NaN. Infinity
    // needs no special case - it propagates through the bounds correctly.
    if (!parsed.maxDepthMeters.isFinite) return false;

    var deepest = parsed.maxDepthMeters;
    var previousTime = -1;
    for (final s in parsed.samples) {
      // libdivecomputer accumulates sample time as it walks the record
      // stream, so a real profile is always non-negative and non-decreasing.
      // Bytes read in the wrong format are not.
      if (s.timeSeconds < 0 || s.timeSeconds < previousTime) return false;
      previousTime = s.timeSeconds;
      if (!s.depthMeters.isFinite) return false;
      if (s.depthMeters < _minPlausibleDepthMeters) return false;
      if (s.depthMeters > deepest) deepest = s.depthMeters;
    }

    if (deepest > maxPlausibleDepthMeters) return false;

    // Cannot go negative: the samples are non-empty and every negative time
    // already returned above, so `previousTime` is at least 0 by here.
    final durationSeconds = math.max(parsed.durationSeconds, previousTime);
    if (durationSeconds > maxPlausibleDuration.inSeconds) return false;

    if (!_withinGross(
      parsed: deepest,
      recorded: recordedMaxDepthMeters,
      floor: _depthFloorMeters,
    )) {
      return false;
    }
    if (!_withinGross(
      parsed: durationSeconds.toDouble(),
      recorded: recordedDuration?.inSeconds.toDouble(),
      floor: _durationFloor.inSeconds.toDouble(),
    )) {
      return false;
    }

    return true;
  }

  /// True unless [parsed] and [recorded] disagree by more than a factor of
  /// [_grossFactor]. A missing, non-positive or non-finite value on either
  /// side carries no information, so it cannot reject anything. [parsed] is
  /// already known finite by the time this runs; [recorded] comes from the
  /// source app and is checked here.
  static bool _withinGross({
    required double parsed,
    required double? recorded,
    required double floor,
  }) {
    if (recorded == null || !recorded.isFinite || recorded <= 0) return true;
    if (parsed <= 0) return true;
    if (parsed > recorded * _grossFactor + floor) return false;
    if (parsed * _grossFactor + floor < recorded) return false;
    return true;
  }
}
