import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/dive_3d/application/spatial_providers.dart';
import 'package:submersion/features/dive_3d/domain/spatial/reckoned_path.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_log/domain/entities/source_profile.dart';
import 'package:submersion/features/dive_log/presentation/providers/active_source_provider.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_providers.dart';
import 'package:submersion/features/dive_sites/domain/entities/dive_site.dart';
import 'package:submersion/features/nav_track/domain/entities/nav_track.dart';
import 'package:submersion/features/nav_track/domain/entities/nav_track_point.dart';

import '../../../helpers/mock_providers.dart';

NavTrack _route({required List<NavTrackPoint> points}) {
  final now = DateTime(2026, 9, 10);
  return NavTrack(
    id: 'route-1',
    diveId: 'd1',
    source: NavTrackSource.seacraftEnc,
    startTime: points.isEmpty ? 0 : points.first.timestamp * 1000,
    endTime: points.isEmpty ? 0 : points.last.timestamp * 1000,
    pointCount: points.length,
    points: points,
    createdAt: now,
    updatedAt: now,
  );
}

Dive diveWithHeadings({bool withGps = true}) => Dive(
  id: 'd1',
  dateTime: DateTime.utc(2026, 1, 1),
  entryLocation: withGps ? const GeoPoint(10.0, 20.0) : null,
  exitLocation: withGps ? const GeoPoint(10.001, 20.001) : null,
  site: const DiveSite(id: 's1', name: 'Reef', maxDepth: 30),
);

SourceProfile headingProfile() {
  final points = <DiveProfilePoint>[];
  for (var i = 0; i <= 30; i++) {
    points.add(
      DiveProfilePoint(
        timestamp: i * 20,
        depth: i < 15 ? i * 2.0 : (30 - i) * 2.0,
        heading: (i * 6).toDouble() % 360,
      ),
    );
  }
  return SourceProfile(
    sourceId: 'src',
    computerId: null,
    isEdited: false,
    points: points,
  );
}

Future<ProviderContainer> makeContainer({
  required Dive? dive,
  SourceProfile? profile,
  NavTrack? route,
}) async {
  final base = await getBaseOverrides(primaryNavTrack: route);
  final container = ProviderContainer(
    overrides: [
      ...base,
      diveProvider('d1').overrideWith((ref) async => dive),
      sourceProfilesProvider('d1').overrideWith(
        (ref) async => profile == null ? const {} : {'src': profile},
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test(
    'reckons a path from profile headings and lands on the exit fix',
    () async {
      final container = await makeContainer(
        dive: diveWithHeadings(),
        profile: headingProfile(),
      );
      final path = await container.read(
        spatialReckonedPathProvider('d1').future,
      );
      expect(path, isNotNull);
      expect(path!.reconstructed, isTrue);
      expect(path.points.length, greaterThan(2));
    },
  );

  test('geometry provider builds the seascape scene', () async {
    final container = await makeContainer(
      dive: diveWithHeadings(),
      profile: headingProfile(),
    );
    final result = await container.read(spatialGeometryProvider('d1').future);
    expect(result, isNotNull);
    final scene = result!.scene;
    expect(scene.layers.length, 5);
    expect(scene.scrubPath!.zs, isNotNull);
    // No coordinates anywhere in this fixture -> synthesized terrain.
    expect(result.bathymetrySourceId, isNull);
  });

  test('null when the dive has no profile', () async {
    final container = await makeContainer(dive: diveWithHeadings());
    final scene = await container.read(spatialGeometryProvider('d1').future);
    expect(scene, isNull);
  });

  test('respects the diver-selected active (non-primary) source', () async {
    final base = await getBaseOverrides();
    // Primary 'src' has 31 points; the active secondary 'src2' has 3 -> the
    // reckoned path length tells us which source's profile was used.
    const secondary = SourceProfile(
      sourceId: 'src2',
      computerId: null,
      isEdited: false,
      points: [
        DiveProfilePoint(timestamp: 0, depth: 0),
        DiveProfilePoint(timestamp: 600, depth: 20),
        DiveProfilePoint(timestamp: 1200, depth: 0),
      ],
    );
    final container = ProviderContainer(
      overrides: [
        ...base,
        diveProvider(
          'd1',
        ).overrideWith((ref) async => diveWithHeadings(withGps: false)),
        sourceProfilesProvider('d1').overrideWith(
          (ref) async => {'src': headingProfile(), 'src2': secondary},
        ),
        activeDiveSourceProvider('d1').overrideWith((ref) => 'src2'),
      ],
    );
    addTearDown(container.dispose);

    final path = await container.read(spatialReckonedPathProvider('d1').future);
    expect(path, isNotNull);
    expect(path!.points.length, 3); // used src2 (3 pts), not primary (31)
  });

  test('works without GPS via the straight-line fallback', () async {
    final container = await makeContainer(
      dive: diveWithHeadings(withGps: false),
      profile: const SourceProfile(
        sourceId: 'src',
        computerId: null,
        isEdited: false,
        points: [
          DiveProfilePoint(timestamp: 0, depth: 0),
          DiveProfilePoint(timestamp: 600, depth: 20),
          DiveProfilePoint(timestamp: 1200, depth: 0),
        ],
      ),
    );
    final scene = await container.read(spatialGeometryProvider('d1').future);
    expect(scene, isNotNull);
  });

  group('a linked underwater route', () {
    List<NavTrackPoint> pointsOf(int count) => [
      for (var i = 0; i < count; i++)
        NavTrackPoint(timestamp: i * 10, north: i * 5.0, east: 0, depth: 5),
    ];

    test('with >=2 points wins over dead reckoning', () async {
      final container = await makeContainer(
        dive: diveWithHeadings(),
        profile: headingProfile(),
        route: _route(points: pointsOf(3)),
      );

      final path = await container.read(
        spatialReckonedPathProvider('d1').future,
      );

      expect(path, isNotNull);
      expect(path!.provenance, PathProvenance.measured);
      expect(path.points, hasLength(3));
    });

    test('with fewer than 2 points falls back to the estimate', () async {
      final container = await makeContainer(
        dive: diveWithHeadings(),
        profile: headingProfile(),
        route: _route(points: pointsOf(1)),
      );

      final path = await container.read(
        spatialReckonedPathProvider('d1').future,
      );

      expect(path, isNotNull);
      expect(path!.provenance, PathProvenance.deadReckoned);
    });

    test('unlinking (null route) restores the estimate', () async {
      final container = await makeContainer(
        dive: diveWithHeadings(),
        profile: headingProfile(),
        // No route override at all: primaryNavTrackForDiveProvider defaults
        // to null via getBaseOverrides, as it would once a route is
        // unlinked.
      );

      final path = await container.read(
        spatialReckonedPathProvider('d1').future,
      );

      expect(path, isNotNull);
      expect(path!.provenance, PathProvenance.deadReckoned);
    });
  });
}
