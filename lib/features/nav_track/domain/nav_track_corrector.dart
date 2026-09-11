import 'dart:math' as math;

import 'package:submersion/features/dive_sites/domain/entities/dive_site.dart';
import 'package:submersion/features/nav_track/domain/entities/nav_track_point.dart';
import 'package:submersion/features/nav_track/domain/nav_track_georef.dart';
import 'package:submersion/features/nav_track/domain/nav_track_segmenter.dart';

/// How a route's recorded end should be reconciled with where the diver
/// says it actually ended.
enum NavTrackEndMode {
  /// No drift correction: the route is used exactly as recorded (after
  /// [NavTrackCorrection.headingOffsetDeg] rotation).
  none,

  /// The route should end where it started -- a loop.
  sameAsStart,

  /// The route should end at [NavTrackCorrection.endPoint], reached via
  /// [NavTrackCorrection.anchor].
  point,

  /// The route should end at the recording's own surface GPS fix, when it
  /// has one (see `NavTrackSegmenter`). Silently behaves as [none] when
  /// the recording has no fix event -- the UI only ever offers this mode
  /// when one exists, so this is a defensive fallback, not a case the
  /// diver is expected to hit.
  gpsFix,
}

/// How a route's raw recording is placed on the map and reconciled with a
/// known end point. Every field is optional to apply: the default value of
/// each corresponds to "make no correction of this kind".
class NavTrackCorrection {
  /// Where the route's local (0, 0) origin sits on the map. Required for
  /// [NavTrackEndMode.point] (to resolve [endPoint] into the route's local
  /// frame); irrelevant to every other mode, since [sameAsStart] and
  /// [gpsFix] targets are already expressed in the recording's own frame.
  final GeoPoint? anchor;

  final NavTrackEndMode endMode;

  /// The target for [NavTrackEndMode.point]. Ignored otherwise.
  final GeoPoint? endPoint;

  /// Fraction of the route's cumulative distance, 0 to 1, up to which the
  /// recording is taken as correct. 0 (default) rubber-bands the whole
  /// route toward the target; 1 disables the correction entirely.
  final double trustFraction;

  /// Clockwise rotation, in degrees, applied to every raw (north, east)
  /// before any drift correction.
  final double headingOffsetDeg;

  const NavTrackCorrection({
    this.anchor,
    this.endMode = NavTrackEndMode.none,
    this.endPoint,
    this.trustFraction = 0,
    this.headingOffsetDeg = 0,
  });

  NavTrackCorrection copyWith({
    GeoPoint? anchor,
    NavTrackEndMode? endMode,
    GeoPoint? endPoint,
    double? trustFraction,
    double? headingOffsetDeg,
  }) {
    return NavTrackCorrection(
      anchor: anchor ?? this.anchor,
      endMode: endMode ?? this.endMode,
      endPoint: endPoint ?? this.endPoint,
      trustFraction: trustFraction ?? this.trustFraction,
      headingOffsetDeg: headingOffsetDeg ?? this.headingOffsetDeg,
    );
  }
}

/// One sample after rotation and drift correction: the local frame the 2D
/// layer, the 3D adapter, and the terrain check all read from. Depth and
/// timestamp pass through [NavTrackCorrector.apply] unchanged.
class CorrectedNavTrackPoint {
  final int timestamp;
  final double east;
  final double north;
  final double depth;

  const CorrectedNavTrackPoint({
    required this.timestamp,
    required this.east,
    required this.north,
    required this.depth,
  });
}

/// Applies a [NavTrackCorrection] to a route's raw samples.
///
/// Pure, and the single place every consumer of a corrected route (the 2D
/// layer, the 3D path adapter, the terrain check) reads from -- see the
/// design spec (2026-09-10-underwater-nav-track-design.md, "Georeferencing
/// and drift correction") for the reasoning behind each step. Never
/// rewrites [NavTrackPoint]s; always produces a fresh list, same length
/// and order as the input.
class NavTrackCorrector {
  const NavTrackCorrector._();

  static List<CorrectedNavTrackPoint> apply(
    List<NavTrackPoint> points,
    NavTrackCorrection correction,
  ) {
    if (points.isEmpty) return const [];

    final rotated = [
      for (final p in points) _rotate(p, correction.headingOffsetDeg),
    ];

    final target = _resolveTarget(points, rotated, correction);
    if (target == null) return rotated;

    final cumulative = _cumulativeDistance(
      points,
      rotated,
      target.lastActiveIndex,
    );
    final sLast = cumulative[target.lastActiveIndex];
    final sTrust = correction.trustFraction.clamp(0.0, 1.0) * sLast;
    final denominator = sLast - sTrust;

    if (denominator <= 0) {
      // trustFraction is 1 (or numerically indistinguishable from it), or
      // the active range has zero length: there is nothing to distribute
      // the residual over, so the recording stands as rotated.
      return rotated;
    }

    final last = rotated[target.lastActiveIndex];
    final residualEast = target.east - last.east;
    final residualNorth = target.north - last.north;

    return [
      for (var i = 0; i < rotated.length; i++)
        if (i > target.lastActiveIndex || cumulative[i] <= sTrust)
          rotated[i]
        else
          _shift(
            rotated[i],
            residualEast * (cumulative[i] - sTrust) / denominator,
            residualNorth * (cumulative[i] - sTrust) / denominator,
          ),
    ];
  }

  /// The correction target and the last index the proportional correction
  /// applies to, or null when [correction] resolves to no correction at
  /// all (mode [NavTrackEndMode.none], or a mode whose inputs are
  /// incomplete: [NavTrackEndMode.point] without both [anchor] and
  /// [endPoint], or [NavTrackEndMode.gpsFix] on a recording with no fix
  /// event).
  ///
  /// The active range's ceiling is the same for every mode but [none]: the
  /// last [NavTrackSampleKind.underwater] or [NavTrackSampleKind.surfaceReckoned]
  /// sample. On a recording with no fix event this is the last raw sample,
  /// i.e. the whole recording, same as before. On a recording with a fix
  /// event (see `NavTrackSegmenter`) it stops one sample before the fix:
  /// everything from the event onward is the device's own GPS-derived
  /// position, excluded from rendering entirely by `NavTrackSampleKind`
  /// (`NavTrackPolylineLayer.kept`, `NavTrackPathAdapter`). Computing the
  /// cumulative distance denominator over the raw recording's full length
  /// -- including a 300+ m post-fix jump and the surface wobble that
  /// follows it -- would swamp the correction budget for the visible
  /// pre-fix portion of the route, making both `sameAsStart` and the trust
  /// slider appear to have no effect on what is actually drawn. Using this
  /// same ceiling for [NavTrackEndMode.point] and [NavTrackEndMode.sameAsStart]
  /// (previously only [NavTrackEndMode.gpsFix] stopped here) is exactly the
  /// fix for that.
  static ({double east, double north, int lastActiveIndex})? _resolveTarget(
    List<NavTrackPoint> points,
    List<CorrectedNavTrackPoint> rotated,
    NavTrackCorrection correction,
  ) {
    if (correction.endMode == NavTrackEndMode.none) return null;

    final segmentation = NavTrackSegmenter.classify(points);
    final lastActiveIndex = _lastActiveIndex(
      segmentation.kinds,
      rotated.length,
    );

    switch (correction.endMode) {
      case NavTrackEndMode.none:
        return null; // handled above; unreachable here
      case NavTrackEndMode.sameAsStart:
        return (
          east: rotated.first.east,
          north: rotated.first.north,
          lastActiveIndex: lastActiveIndex,
        );
      case NavTrackEndMode.point:
        final anchor = correction.anchor;
        final endPoint = correction.endPoint;
        if (anchor == null || endPoint == null) return null;
        final offset = offsetFromAnchor(anchor, endPoint);
        return (
          east: offset.east,
          north: offset.north,
          lastActiveIndex: lastActiveIndex,
        );
      case NavTrackEndMode.gpsFix:
        if (segmentation.fixEvents.isEmpty) return null;
        final fixIndex = segmentation.fixEvents.first.index;
        final fixed = rotated[fixIndex];
        return (
          east: fixed.east,
          north: fixed.north,
          lastActiveIndex: lastActiveIndex,
        );
    }
  }

  /// The last sample still part of the dead-reckoned swim path: the last
  /// [NavTrackSampleKind.underwater] or [NavTrackSampleKind.surfaceReckoned]
  /// entry. Falls back to the last raw sample when [kinds] contains none of
  /// either (an edge case the parser's `tooShort` check should already
  /// prevent, but this keeps the corrector from producing a zero-length
  /// active range instead of failing loudly elsewhere).
  static int _lastActiveIndex(List<NavTrackSampleKind> kinds, int length) {
    for (var i = kinds.length - 1; i >= 0; i--) {
      final kind = kinds[i];
      if (kind == NavTrackSampleKind.underwater ||
          kind == NavTrackSampleKind.surfaceReckoned) {
        return i;
      }
    }
    return length - 1;
  }

  static CorrectedNavTrackPoint _rotate(
    NavTrackPoint p,
    double headingOffsetDeg,
  ) {
    if (headingOffsetDeg == 0) {
      return CorrectedNavTrackPoint(
        timestamp: p.timestamp,
        east: p.east,
        north: p.north,
        depth: p.depth,
      );
    }
    final theta = headingOffsetDeg * math.pi / 180.0;
    final cosT = math.cos(theta);
    final sinT = math.sin(theta);
    return CorrectedNavTrackPoint(
      timestamp: p.timestamp,
      // A clockwise rotation by theta (matching compass bearings: 0 =
      // north, 90 = east): a point due north rotates toward due east as
      // theta grows toward 90.
      east: p.east * cosT + p.north * sinT,
      north: p.north * cosT - p.east * sinT,
      depth: p.depth,
    );
  }

  /// Cumulative distance for indices `0..upToIndex` inclusive.
  ///
  /// Prefers the device's own `distance` channel when every sample in that
  /// range has one and they are non-decreasing (a scooter's dead-reckoning
  /// error grows with distance travelled, not with elapsed time, so a
  /// route that sits still should not accumulate correction meanwhile);
  /// otherwise falls back to the 2D path length of the rotated points
  /// (equivalent to the raw points' path length, since rotation preserves
  /// distance).
  static List<double> _cumulativeDistance(
    List<NavTrackPoint> points,
    List<CorrectedNavTrackPoint> rotated,
    int upToIndex,
  ) {
    var deviceDistanceUsable = points[0].distance != null;
    if (deviceDistanceUsable) {
      for (var i = 1; i <= upToIndex; i++) {
        final previous = points[i - 1].distance;
        final current = points[i].distance;
        if (previous == null || current == null || current < previous) {
          deviceDistanceUsable = false;
          break;
        }
      }
    }
    if (deviceDistanceUsable) {
      return [for (var i = 0; i <= upToIndex; i++) points[i].distance!];
    }

    final result = List<double>.filled(upToIndex + 1, 0);
    for (var i = 1; i <= upToIndex; i++) {
      final dEast = rotated[i].east - rotated[i - 1].east;
      final dNorth = rotated[i].north - rotated[i - 1].north;
      result[i] = result[i - 1] + math.sqrt(dEast * dEast + dNorth * dNorth);
    }
    return result;
  }

  static CorrectedNavTrackPoint _shift(
    CorrectedNavTrackPoint p,
    double dEast,
    double dNorth,
  ) => CorrectedNavTrackPoint(
    timestamp: p.timestamp,
    east: p.east + dEast,
    north: p.north + dNorth,
    depth: p.depth,
  );
}
