import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_providers.dart';
import 'package:submersion/features/nav_track/domain/entities/nav_track.dart';
import 'package:submersion/features/nav_track/domain/entities/nav_track_point.dart';
import 'package:submersion/features/nav_track/presentation/pages/nav_track_list_page.dart';
import 'package:submersion/features/nav_track/presentation/providers/nav_track_providers.dart';
import 'package:submersion/features/nav_track/presentation/widgets/nav_track_polyline_layer.dart';
import 'package:submersion/features/nav_track/presentation/widgets/nav_track_shape_thumbnail.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../../helpers/mock_providers.dart';

List<NavTrackPoint> _hydratedPoints() => [
  for (var i = 0; i < 5; i++)
    NavTrackPoint(
      timestamp: 1755856800 + i * 10,
      north: i * 10.0,
      east: 0,
      depth: 5,
    ),
];

NavTrack _route({
  required String id,
  String? diveId,
  String? name,
  String? deviceName,
  double? distance,
  double? maxDepth,
  double? anchorLatitude,
  double? anchorLongitude,
}) => NavTrack(
  id: id,
  diveId: diveId,
  linkMode: diveId == null ? null : NavTrackLinkMode.auto,
  name: name,
  deviceName: deviceName,
  source: NavTrackSource.seacraftEnc,
  sourceRef: '$id.csv',
  startTime: 1755856800000,
  endTime: 1755860400000,
  pointCount: 5,
  totalDistance: distance,
  maxDepth: maxDepth,
  anchorLatitude: anchorLatitude,
  anchorLongitude: anchorLongitude,
  createdAt: DateTime(2026, 8, 22),
  updatedAt: DateTime(2026, 8, 22),
);

Future<void> _pump(
  WidgetTester tester, {
  required List<NavTrack> routes,
  Dive? linkedDive,
  Map<String, NavTrack>? hydrated,
}) async {
  final overrides = await getBaseOverrides();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...overrides,
        allNavTracksProvider.overrideWith((ref) async => routes),
        if (linkedDive != null)
          diveProvider(linkedDive.id).overrideWith((ref) async => linkedDive),
        if (hydrated != null)
          for (final entry in hydrated.entries)
            navTrackByIdProvider(
              entry.key,
            ).overrideWith((ref) async => entry.value),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: NavTrackListPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders route rows with distance, depth and an unlinked chip', (
    tester,
  ) async {
    await _pump(
      tester,
      routes: [
        _route(
          id: 'r1',
          name: 'Wreck dive',
          deviceName: 'Seacraft ENC3',
          distance: 1050,
          maxDepth: 38,
        ),
      ],
    );

    expect(find.text('Wreck dive'), findsOneWidget);
    expect(find.text('unlinked'), findsOneWidget);
  });

  testWidgets('a linked route shows a Dive # chip instead of unlinked', (
    tester,
  ) async {
    final dive = Dive(
      id: 'dive-1',
      diveNumber: 412,
      dateTime: DateTime(2026, 8, 22, 10, 8),
    );
    await _pump(
      tester,
      routes: [_route(id: 'r1', name: 'Wreck dive', diveId: 'dive-1')],
      linkedDive: dive,
    );

    expect(find.text('unlinked'), findsNothing);
    expect(find.textContaining('Dive'), findsOneWidget);
    expect(find.textContaining('#412'), findsOneWidget);
  });

  testWidgets('shows an empty message with no routes', (tester) async {
    await _pump(tester, routes: const []);

    expect(find.text('No underwater routes yet.'), findsOneWidget);
  });

  testWidgets(
    'an unanchored route\'s shape thumbnail renders the actual route, not '
    'an empty shape (item 9: the list query omits points, so the thumbnail '
    'must hydrate them itself rather than reading the unhydrated list row)',
    (tester) async {
      final listRow = _route(id: 'r1', name: 'Wreck dive');
      final hydratedRoute = listRow.copyWith(points: _hydratedPoints());
      await _pump(tester, routes: [listRow], hydrated: {'r1': hydratedRoute});

      final thumbnail = tester.widget<NavTrackShapeThumbnail>(
        find.byType(NavTrackShapeThumbnail),
      );
      expect(thumbnail.points, isNotEmpty);
      expect(thumbnail.points, hydratedRoute.points);
    },
  );

  testWidgets(
    'the list row\'s duration stops at the last dead-reckoned sample, not '
    'the raw recording span (item 8: a GPS-fix jump and the post-surfacing '
    'tail must not inflate the displayed duration)',
    (tester) async {
      final points = [
        const NavTrackPoint(timestamp: 0, north: 0, east: 0, depth: 5),
        // Last active sample: 600 s (10 min) after the first.
        const NavTrackPoint(
          timestamp: 600,
          north: 50,
          east: 0,
          depth: 0.1,
          distance: 50,
        ),
        // Fix event: >50 m step in <=5 s at the surface -- gpsFixed from
        // here on, and NOT part of the active dead-reckoned range.
        const NavTrackPoint(
          timestamp: 602,
          north: 500,
          east: 0,
          depth: 0.1,
          distance: 50,
        ),
        // The raw recording keeps going for another hour after the fix.
        const NavTrackPoint(
          timestamp: 4200,
          north: 505,
          east: 0,
          depth: 0.1,
          distance: 50,
        ),
      ];
      final listRow = _route(id: 'r1', name: 'Wreck dive').copyWith(
        startTime: points.first.timestamp * 1000,
        endTime: points.last.timestamp * 1000,
      );
      final hydratedRoute = listRow.copyWith(points: points);
      await _pump(tester, routes: [listRow], hydrated: {'r1': hydratedRoute});

      // Active range: 10 min. Raw span: 1h 10min. Only the former may show.
      expect(find.textContaining('10min'), findsOneWidget);
      expect(find.textContaining('1h 10min'), findsNothing);
    },
  );

  testWidgets(
    'an anchored route\'s map overlay actually renders the route, not an '
    'empty polyline (item 9: the map pane must hydrate points per row too)',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final listRow = _route(
        id: 'r1',
        name: 'Wreck dive',
        anchorLatitude: 47.1,
        anchorLongitude: 8.3,
      );
      final hydratedRoute = listRow.copyWith(points: _hydratedPoints());
      await _pump(tester, routes: [listRow], hydrated: {'r1': hydratedRoute});

      expect(find.byType(FlutterMap), findsOneWidget);
      final layer = tester.widget<NavTrackPolylineLayer>(
        find.byType(NavTrackPolylineLayer),
      );
      expect(layer.route.points, isNotEmpty);
      expect(layer.route.points, hydratedRoute.points);
    },
  );
}
