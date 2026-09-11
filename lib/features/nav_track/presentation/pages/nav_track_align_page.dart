import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import 'package:submersion/core/utils/geo_math.dart';
import 'package:submersion/features/bathymetry/application/bathymetry_providers.dart';
import 'package:submersion/features/bathymetry/data/bathymetry_repository.dart';
import 'package:submersion/features/bathymetry/presentation/bathymetry_depth_overlay_layer.dart';
import 'package:submersion/features/bathymetry/presentation/depth_overlay_toggle_button.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_providers.dart';
import 'package:submersion/features/dive_sites/domain/entities/dive_site.dart';
import 'package:submersion/features/dive_sites/presentation/providers/site_providers.dart';
import 'package:submersion/features/maps/data/services/tile_cache_service.dart';
import 'package:submersion/features/maps/presentation/providers/map_tile_providers.dart';
import 'package:submersion/features/maps/presentation/widgets/trackpad_zoom_map.dart';
import 'package:submersion/features/nav_track/domain/entities/nav_track.dart';
import 'package:submersion/features/nav_track/domain/entities/nav_track_point.dart';
import 'package:submersion/features/nav_track/domain/nav_track_corrector.dart';
import 'package:submersion/features/nav_track/domain/nav_track_georef.dart';
import 'package:submersion/features/nav_track/domain/nav_track_segmenter.dart';
import 'package:submersion/features/nav_track/domain/nav_track_terrain_check.dart';
import 'package:submersion/features/nav_track/presentation/providers/nav_track_providers.dart';
import 'package:submersion/features/nav_track/presentation/widgets/nav_track_polyline_layer.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// What the crosshair-and-pan flow is currently placing, or nothing.
enum _Placing { none, start, end }

/// Cumulative distance per point, in metres, from the route's own first
/// sample -- presentation-local because the trust slider is the only reader
/// that needs it purely as a distance axis (unlike `NavTrackCorrector`,
/// which needs it truncated at the gpsFix cutoff and prefers the device's
/// own distance channel; duplicating that nuance here would only make the
/// slider's numbers disagree with the correction actually applied for no
/// benefit, so this always uses path length over every raw sample).
List<double> cumulativeDistances(List<NavTrackPoint> points) {
  final result = List<double>.filled(points.length, 0);
  for (var i = 1; i < points.length; i++) {
    final dNorth = points[i].north - points[i - 1].north;
    final dEast = points[i].east - points[i - 1].east;
    result[i] = result[i - 1] + math.sqrt(dNorth * dNorth + dEast * dEast);
  }
  return result;
}

/// The alignment page (spec 2026-09-10-underwater-nav-track-design.md, "The
/// alignment page"): start point, end point, trust slider, rotation and the
/// terrain check, all against a transient in-memory [NavTrackCorrection]
/// that is only written back with "Save".
///
/// Renders the route by constructing a transient [NavTrack] copy carrying
/// the in-progress correction rather than extending [NavTrackPolylineLayer]
/// with a correction-override parameter: the layer already reads everything
/// it needs from a [NavTrack], and building one here keeps that widget
/// untouched.
class NavTrackAlignPage extends ConsumerStatefulWidget {
  const NavTrackAlignPage({super.key, required this.routeId});

  final String routeId;

  @override
  ConsumerState<NavTrackAlignPage> createState() => _NavTrackAlignPageState();
}

class _NavTrackAlignPageState extends ConsumerState<NavTrackAlignPage> {
  final MapController _mapController = MapController();
  Timer? _terrainDebounce;

  bool _initialized = false;
  NavTrackCorrection _correction = const NavTrackCorrection();
  _Placing _placing = _Placing.none;
  NavTrackTerrainCheckResult? _terrainResult;

  static const Duration _terrainDebounceDuration = Duration(milliseconds: 300);

  @override
  void dispose() {
    _terrainDebounce?.cancel();
    super.dispose();
  }

  void _initFromRoute(NavTrack route) {
    if (_initialized) return;
    _initialized = true;
    var correction = route.correction;
    // Propose "same as start" when the raw recording already ends close to
    // where it started -- only as a starting suggestion, so it never
    // overrides a correction the diver already set on a previous visit.
    if (correction.endMode == NavTrackEndMode.none &&
        route.points.length >= 2 &&
        _rawEndDistanceFromStart(route.points) <= 50) {
      correction = correction.copyWith(endMode: NavTrackEndMode.sameAsStart);
    }
    _correction = correction;
    _scheduleTerrainCheck(route);
  }

  double _rawEndDistanceFromStart(List<NavTrackPoint> points) {
    final first = points.first;
    final last = points.last;
    final dNorth = last.north - first.north;
    final dEast = last.east - first.east;
    return math.sqrt(dNorth * dNorth + dEast * dEast);
  }

  void _updateCorrection(
    NavTrackCorrection Function(NavTrackCorrection) fn,
    NavTrack route,
  ) {
    setState(() => _correction = fn(_correction));
    _scheduleTerrainCheck(route);
  }

  void _scheduleTerrainCheck(NavTrack route) {
    _terrainDebounce?.cancel();
    _terrainDebounce = Timer(
      _terrainDebounceDuration,
      () => _runTerrainCheck(route),
    );
  }

  Future<void> _runTerrainCheck(NavTrack route) async {
    final anchor = _correction.anchor;
    if (anchor == null || route.points.length < 2) {
      if (mounted) setState(() => _terrainResult = null);
      return;
    }
    final corrected = NavTrackCorrector.apply(route.points, _correction);
    final grid = await ref.read(
      bathymetryGridProvider(BathymetryRepository.quantize(anchor)).future,
    );
    if (!mounted || grid == null) {
      if (mounted) setState(() => _terrainResult = null);
      return;
    }
    setState(
      () => _terrainResult = NavTrackTerrainCheck.run(corrected, anchor, grid),
    );
  }

  /// A transient [NavTrack] carrying [_correction] instead of the persisted
  /// one, for the map layers that read a [NavTrack] directly.
  NavTrack _transientRoute(NavTrack base) => NavTrack(
    id: base.id,
    diveId: base.diveId,
    linkMode: base.linkMode,
    isPrimary: base.isPrimary,
    siteId: base.siteId,
    source: base.source,
    sourceRef: base.sourceRef,
    deviceName: base.deviceName,
    name: base.name,
    equipmentId: base.equipmentId,
    startTime: base.startTime,
    endTime: base.endTime,
    tzOffsetMinutes: base.tzOffsetMinutes,
    timeOffsetSeconds: base.timeOffsetSeconds,
    pointCount: base.pointCount,
    totalDistance: base.totalDistance,
    maxDepth: base.maxDepth,
    maxSpeed: base.maxSpeed,
    avgSpeed: base.avgSpeed,
    anchorLatitude: _correction.anchor?.latitude,
    anchorLongitude: _correction.anchor?.longitude,
    endMode: _correction.endMode,
    endLatitude: _correction.endPoint?.latitude,
    endLongitude: _correction.endPoint?.longitude,
    trustFraction: _correction.trustFraction,
    headingOffsetDeg: _correction.headingOffsetDeg,
    points: base.points,
    createdAt: base.createdAt,
    updatedAt: base.updatedAt,
  );

  Future<void> _save(NavTrack route) async {
    await ref
        .read(navTrackRepositoryProvider)
        .updateCorrection(route.id, _correction);
    if (mounted) context.pop();
  }

  void _startPlacing(_Placing target) => setState(() => _placing = target);

  void _resetCorrection() => setState(() {
    _correction = const NavTrackCorrection();
    _terrainResult = null;
  });

  void _setPointHere(NavTrack route) {
    final center = _mapController.camera.center;
    final point = GeoPoint(center.latitude, center.longitude);
    if (_placing == _Placing.start) {
      _updateCorrection((c) => c.copyWith(anchor: point), route);
    } else if (_placing == _Placing.end) {
      _updateCorrection(
        (c) => c.copyWith(endMode: NavTrackEndMode.point, endPoint: point),
        route,
      );
    }
    setState(() => _placing = _Placing.none);
  }

  void _dragPoint(NavTrack route, bool isStart, Offset delta) {
    final current = isStart ? _correction.anchor : _correction.endPoint;
    if (current == null) return;
    final zoom = _mapController.camera.zoom;
    final metersPerPixel =
        156543.03392 *
        math.cos(current.latitude * math.pi / 180) /
        math.pow(2, zoom);
    final dLon =
        delta.dx * metersPerPixel / metersPerDegreeLongitude(current.latitude);
    final dLat = -delta.dy * metersPerPixel / metersPerDegreeLatitude;
    final moved = GeoPoint(current.latitude + dLat, current.longitude + dLon);
    if (isStart) {
      _updateCorrection((c) => c.copyWith(anchor: moved), route);
    } else {
      _updateCorrection((c) => c.copyWith(endPoint: moved), route);
    }
  }

  @override
  Widget build(BuildContext context) {
    final routeAsync = ref.watch(navTrackByIdProvider(widget.routeId));
    final l10n = context.l10n;
    return routeAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) =>
          Scaffold(body: Center(child: Text(l10n.navTrack_common_loadError))),
      data: (route) {
        if (route == null) {
          return Scaffold(
            body: Center(child: Text(l10n.navTrack_common_notFound)),
          );
        }
        _initFromRoute(route);
        return _AlignPageBody(state: this, route: route);
      },
    );
  }
}

class _AlignPageBody extends ConsumerWidget {
  const _AlignPageBody({required this.state, required this.route});

  final _NavTrackAlignPageState state;
  final NavTrack route;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final correction = state._correction;
    final anchor = correction.anchor;
    final transientRoute = state._transientRoute(route);
    final fixEvents = NavTrackSegmenter.classify(route.points).fixEvents;
    final hasFix = fixEvents.isNotEmpty;
    final cumulative = cumulativeDistances(route.points);
    final totalDistance = cumulative.isEmpty ? 0.0 : cumulative.last;
    final trustedDistance = correction.trustFraction * totalDistance;

    final initialCenter = anchor != null
        ? LatLng(anchor.latitude, anchor.longitude)
        : const LatLng(0, 0);
    final l10n = context.l10n;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.navTrack_align_title),
        actions: [
          IconButton(
            key: const ValueKey('nav-track-align-reset'),
            icon: const Icon(Icons.restore),
            tooltip: l10n.navTrack_align_resetTooltip,
            onPressed: state._resetCorrection,
          ),
          IconButton(
            key: const ValueKey('nav-track-align-3d'),
            icon: const Icon(Icons.view_in_ar),
            tooltip: l10n.navTrack_common_open3dTooltip,
            onPressed: () => context.push('/nav-routes/${route.id}/3d'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                TrackpadZoomMap(
                  controller: state._mapController,
                  child: FlutterMap(
                    mapController: state._mapController,
                    options: MapOptions(
                      initialCenter: initialCenter,
                      initialZoom: anchor != null ? 15 : 3,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: ref.watch(mapTileUrlProvider),
                        userAgentPackageName: 'app.submersion',
                        maxZoom: ref.watch(mapTileMaxZoomProvider),
                        tileProvider: TileCacheService.instance.isInitialized
                            ? TileCacheService.instance.getTileProvider()
                            : null,
                      ),
                      if (anchor != null)
                        BathymetryDepthOverlayLayer(location: anchor),
                      NavTrackPolylineLayer(route: transientRoute),
                      if (anchor != null && hasFix)
                        _GpsFixDotsLayer(
                          route: route,
                          anchor: anchor,
                          correction: correction,
                        ),
                      if (anchor != null && state._terrainResult != null)
                        _ConflictDotsLayer(
                          route: route,
                          anchor: anchor,
                          correction: correction,
                          result: state._terrainResult!,
                        ),
                      if (anchor != null)
                        _DraggableMarker(
                          point: anchor,
                          color: Colors.green,
                          keyValue: 'nav-track-align-start-marker',
                          onDrag: (d) => state._dragPoint(route, true, d),
                        ),
                      if (correction.endMode == NavTrackEndMode.point &&
                          correction.endPoint != null)
                        _DraggableMarker(
                          point: correction.endPoint!,
                          color: Colors.red,
                          keyValue: 'nav-track-align-end-marker',
                          onDrag: (d) => state._dragPoint(route, false, d),
                        ),
                    ],
                  ),
                ),
                if (state._placing != _Placing.none)
                  const IgnorePointer(
                    child: Center(
                      child: Icon(Icons.add, size: 32, color: Colors.black87),
                    ),
                  ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: anchor == null
                      ? const SizedBox.shrink()
                      : DepthOverlayToggleButton(siteLocation: anchor),
                ),
                if (state._placing != _Placing.none)
                  Positioned(
                    bottom: 16,
                    left: 16,
                    right: 16,
                    child: FilledButton(
                      key: const ValueKey('nav-track-align-set-here'),
                      onPressed: () => state._setPointHere(route),
                      child: Text(
                        state._placing == _Placing.start
                            ? l10n.navTrack_align_setStartHere
                            : l10n.navTrack_align_setEndHere,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          _ControlsPanel(
            state: state,
            route: route,
            correction: correction,
            hasFix: hasFix,
            totalDistance: totalDistance,
            trustedDistance: trustedDistance,
          ),
        ],
      ),
    );
  }
}

class _ControlsPanel extends ConsumerWidget {
  const _ControlsPanel({
    required this.state,
    required this.route,
    required this.correction,
    required this.hasFix,
    required this.totalDistance,
    required this.trustedDistance,
  });

  final _NavTrackAlignPageState state;
  final NavTrack route;
  final NavTrackCorrection correction;
  final bool hasFix;
  final double totalDistance;
  final double trustedDistance;

  Future<GeoPoint?> _diveEntryLocation(WidgetRef ref) async {
    final diveId = route.diveId;
    if (diveId == null) return null;
    final dive = await ref.read(diveProvider(diveId).future);
    return dive?.entryLocation;
  }

  Future<GeoPoint?> _siteLocation(WidgetRef ref) async {
    final siteId = route.siteId;
    if (siteId == null) return null;
    final site = await ref.read(siteProvider(siteId).future);
    return site?.location;
  }

  int _trustedDurationSeconds() {
    if (route.points.isEmpty || totalDistance <= 0) return 0;
    final cumulative = cumulativeDistances(route.points);
    for (var i = 0; i < cumulative.length; i++) {
      if (cumulative[i] >= trustedDistance) {
        return route.points[i].timestamp - route.points.first.timestamp;
      }
    }
    return route.points.last.timestamp - route.points.first.timestamp;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trustedMinutes = (_trustedDurationSeconds() / 60).round();
    final l10n = context.l10n;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                FilledButton.tonal(
                  key: const ValueKey('nav-track-align-place-start'),
                  onPressed: () => state._startPlacing(_Placing.start),
                  child: Text(l10n.navTrack_align_setStartOnMap),
                ),
                FutureBuilder<GeoPoint?>(
                  future: _diveEntryLocation(ref),
                  builder: (context, snapshot) {
                    final location = snapshot.data;
                    if (location == null) return const SizedBox.shrink();
                    return ActionChip(
                      key: const ValueKey('nav-track-align-from-dive-entry'),
                      label: Text(l10n.navTrack_align_fromDiveEntry),
                      onPressed: () => state._updateCorrection(
                        (c) => c.copyWith(anchor: location),
                        route,
                      ),
                    );
                  },
                ),
                FutureBuilder<GeoPoint?>(
                  future: _siteLocation(ref),
                  builder: (context, snapshot) {
                    final location = snapshot.data;
                    if (location == null) return const SizedBox.shrink();
                    return ActionChip(
                      key: const ValueKey('nav-track-align-from-site'),
                      label: Text(l10n.navTrack_align_fromSite),
                      onPressed: () => state._updateCorrection(
                        (c) => c.copyWith(anchor: location),
                        route,
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(l10n.navTrack_align_endLabel),
                DropdownButton<NavTrackEndMode>(
                  key: const ValueKey('nav-track-align-end-mode'),
                  value: correction.endMode,
                  items: [
                    DropdownMenuItem(
                      value: NavTrackEndMode.none,
                      child: Text(l10n.navTrack_align_endMode_none),
                    ),
                    DropdownMenuItem(
                      value: NavTrackEndMode.sameAsStart,
                      child: Text(l10n.navTrack_align_endMode_sameAsStart),
                    ),
                    DropdownMenuItem(
                      value: NavTrackEndMode.point,
                      child: Text(l10n.navTrack_align_endMode_point),
                    ),
                    if (hasFix)
                      DropdownMenuItem(
                        value: NavTrackEndMode.gpsFix,
                        child: Text(l10n.navTrack_align_endMode_gpsFix),
                      ),
                  ],
                  onChanged: (mode) {
                    if (mode == null) return;
                    if (mode == NavTrackEndMode.point) {
                      state._startPlacing(_Placing.end);
                    }
                    state._updateCorrection(
                      (c) => c.copyWith(endMode: mode),
                      route,
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l10n.navTrack_align_trustSummary(
                trustedDistance.toStringAsFixed(0),
                trustedMinutes,
              ),
            ),
            Slider(
              key: const ValueKey('nav-track-align-trust-slider'),
              value: correction.trustFraction.clamp(0.0, 1.0),
              onChanged: totalDistance <= 0
                  ? null
                  : (value) => state._updateCorrection(
                      (c) => c.copyWith(trustFraction: value),
                      route,
                    ),
            ),
            Row(
              children: [
                Text(l10n.navTrack_align_rotationLabel),
                IconButton(
                  key: const ValueKey('nav-track-align-rotate-down'),
                  icon: const Icon(Icons.remove),
                  onPressed: () => state._updateCorrection(
                    (c) =>
                        c.copyWith(headingOffsetDeg: c.headingOffsetDeg - 0.5),
                    route,
                  ),
                ),
                Text(
                  l10n.navTrack_align_rotationDegrees(
                    correction.headingOffsetDeg.toStringAsFixed(1),
                  ),
                ),
                IconButton(
                  key: const ValueKey('nav-track-align-rotate-up'),
                  icon: const Icon(Icons.add),
                  onPressed: () => state._updateCorrection(
                    (c) =>
                        c.copyWith(headingOffsetDeg: c.headingOffsetDeg + 0.5),
                    route,
                  ),
                ),
              ],
            ),
            if (state._terrainResult != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  key: const ValueKey('nav-track-align-terrain-summary'),
                  state._terrainResult!.summaryLine(l10n),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(
                  key: const ValueKey('nav-track-align-cancel'),
                  onPressed: () => context.pop(),
                  child: Text(l10n.navTrack_common_cancel),
                ),
                const Spacer(),
                FilledButton(
                  key: const ValueKey('nav-track-align-save'),
                  onPressed: () => state._save(route),
                  child: Text(l10n.navTrack_common_save),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A correction-target marker that reports pixel-delta drags. Fine
/// adjustment uses screen-pixel deltas converted to degrees via the local
/// Web Mercator metres-per-pixel formula rather than any flutter_map
/// internal API, so it stays independent of the package's camera
/// implementation.
class _DraggableMarker extends StatelessWidget {
  const _DraggableMarker({
    required this.point,
    required this.color,
    required this.keyValue,
    required this.onDrag,
  });

  final GeoPoint point;
  final Color color;
  final String keyValue;
  final ValueChanged<Offset> onDrag;

  @override
  Widget build(BuildContext context) {
    return MarkerLayer(
      markers: [
        Marker(
          point: LatLng(point.latitude, point.longitude),
          width: 36,
          height: 36,
          child: GestureDetector(
            key: ValueKey(keyValue),
            onPanUpdate: (details) => onDrag(details.delta),
            child: Container(
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GpsFixDotsLayer extends StatelessWidget {
  const _GpsFixDotsLayer({
    required this.route,
    required this.anchor,
    required this.correction,
  });

  final NavTrack route;
  final GeoPoint anchor;
  final NavTrackCorrection correction;

  @override
  Widget build(BuildContext context) {
    final kinds = NavTrackSegmenter.classify(route.points).kinds;
    final corrected = NavTrackCorrector.apply(route.points, correction);
    final markers = <Marker>[
      for (var i = 0; i < corrected.length; i++)
        if (kinds[i] == NavTrackSampleKind.gpsFixed)
          Marker(
            point: LatLng(
              offsetToGeoPoint(
                anchor,
                east: corrected[i].east,
                north: corrected[i].north,
              ).latitude,
              offsetToGeoPoint(
                anchor,
                east: corrected[i].east,
                north: corrected[i].north,
              ).longitude,
            ),
            width: 6,
            height: 6,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.yellow,
                shape: BoxShape.circle,
              ),
            ),
          ),
    ];
    return MarkerLayer(markers: markers);
  }
}

class _ConflictDotsLayer extends StatelessWidget {
  const _ConflictDotsLayer({
    required this.route,
    required this.anchor,
    required this.correction,
    required this.result,
  });

  final NavTrack route;
  final GeoPoint anchor;
  final NavTrackCorrection correction;
  final NavTrackTerrainCheckResult result;

  @override
  Widget build(BuildContext context) {
    final corrected = NavTrackCorrector.apply(route.points, correction);
    final conflicts = result.conflictingIndices;
    final markers = <Marker>[
      for (final i in conflicts)
        if (i < corrected.length)
          Marker(
            point: LatLng(
              offsetToGeoPoint(
                anchor,
                east: corrected[i].east,
                north: corrected[i].north,
              ).latitude,
              offsetToGeoPoint(
                anchor,
                east: corrected[i].east,
                north: corrected[i].north,
              ).longitude,
            ),
            width: 8,
            height: 8,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.red,
                shape: BoxShape.circle,
              ),
            ),
          ),
    ];
    return MarkerLayer(markers: markers);
  }
}
