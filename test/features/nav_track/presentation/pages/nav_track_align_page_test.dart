import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:submersion/features/bathymetry/application/bathymetry_providers.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_providers.dart';
import 'package:submersion/features/dive_sites/domain/entities/dive_site.dart';
import 'package:submersion/features/dive_sites/presentation/providers/site_providers.dart';
import 'package:submersion/features/nav_track/data/repositories/nav_track_repository.dart';
import 'package:submersion/features/nav_track/domain/entities/nav_track.dart';
import 'package:submersion/features/nav_track/domain/entities/nav_track_point.dart';
import 'package:submersion/features/nav_track/domain/nav_track_corrector.dart';
import 'package:submersion/features/nav_track/presentation/pages/nav_track_align_page.dart';
import 'package:submersion/features/nav_track/presentation/providers/nav_track_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../../helpers/mock_providers.dart';

/// Records `updateCorrection` calls instead of touching a real database.
class _RecordingNavTrackRepository extends NavTrackRepository {
  String? lastRouteId;
  NavTrackCorrection? lastCorrection;

  @override
  Future<void> updateCorrection(
    String routeId,
    NavTrackCorrection correction,
  ) async {
    lastRouteId = routeId;
    lastCorrection = correction;
  }
}

List<NavTrackPoint> _points() => [
  for (var i = 0; i < 10; i++)
    NavTrackPoint(
      timestamp: 1755856800 + i * 10,
      north: i * 10.0,
      east: i * 5.0,
      depth: 5.0 + i,
      distance: i * 11.0,
    ),
];

NavTrack _route({String? diveId, String? siteId}) => NavTrack(
  id: 'r1',
  diveId: diveId,
  siteId: siteId,
  linkMode: diveId == null ? null : NavTrackLinkMode.auto,
  source: NavTrackSource.seacraftEnc,
  sourceRef: 'r1.csv',
  startTime: 1755856800000,
  endTime: 1755860400000,
  pointCount: 10,
  points: _points(),
  createdAt: DateTime(2026, 8, 22),
  updatedAt: DateTime(2026, 8, 22),
);

Future<_RecordingNavTrackRepository> _pump(
  WidgetTester tester, {
  required NavTrack route,
  Dive? linkedDive,
  DiveSite? site,
}) async {
  final overrides = await getBaseOverrides();
  final repository = _RecordingNavTrackRepository();
  final router = GoRouter(
    initialLocation: '/nav-routes/${route.id}',
    routes: [
      GoRoute(
        path: '/nav-routes/:id',
        builder: (context, state) =>
            const Scaffold(body: Text('ROUTE_DETAIL_PAGE')),
      ),
      GoRoute(
        path: '/nav-routes/:id/align',
        builder: (context, state) =>
            NavTrackAlignPage(routeId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/nav-routes/:id/3d',
        builder: (context, state) =>
            const Scaffold(body: Text('ROUTE_3D_PAGE')),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...overrides,
        navTrackByIdProvider(route.id).overrideWith((ref) async => route),
        navTrackRepositoryProvider.overrideWithValue(repository),
        if (linkedDive != null)
          diveProvider(linkedDive.id).overrideWith((ref) async => linkedDive),
        if (site != null)
          siteProvider(site.id).overrideWith((ref) async => site),
        // Never hit the real bathymetry cache/network from a widget test.
        bathymetryGridProvider.overrideWith((ref, cell) async => null),
      ],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  router.push('/nav-routes/${route.id}/align');
  await tester.pumpAndSettle();
  return repository;
}

void main() {
  testWidgets(
    'setting a start point on the map and saving persists the anchor',
    (tester) async {
      final repository = await _pump(tester, route: _route());

      await tester.tap(
        find.byKey(const ValueKey('nav-track-align-place-start')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('nav-track-align-set-here')));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('nav-track-align-save')));
      await tester.pumpAndSettle();

      expect(repository.lastRouteId, 'r1');
      expect(repository.lastCorrection?.anchor, isNotNull);
    },
  );

  testWidgets(
    'the "From dive entry" chip sets the anchor from the linked dive',
    (tester) async {
      final dive = Dive(
        id: 'dive-1',
        diveNumber: 1,
        dateTime: DateTime(2026, 8, 22, 10, 8),
        entryLocation: const GeoPoint(46.9, 7.2),
      );
      final repository = await _pump(
        tester,
        route: _route(diveId: 'dive-1'),
        linkedDive: dive,
      );

      expect(
        find.byKey(const ValueKey('nav-track-align-from-dive-entry')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('nav-track-align-from-dive-entry')),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('nav-track-align-save')));
      await tester.pumpAndSettle();

      expect(repository.lastCorrection?.anchor, const GeoPoint(46.9, 7.2));
    },
  );

  testWidgets('the "From site" chip sets the anchor from the route\'s site', (
    tester,
  ) async {
    const site = DiveSite(
      id: 'site-1',
      name: 'Test Site',
      location: GeoPoint(47.1, 8.3),
    );
    final repository = await _pump(
      tester,
      route: _route(siteId: 'site-1'),
      site: site,
    );

    await tester.tap(find.byKey(const ValueKey('nav-track-align-from-site')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('nav-track-align-save')));
    await tester.pumpAndSettle();

    expect(repository.lastCorrection?.anchor, const GeoPoint(47.1, 8.3));
  });

  testWidgets(
    'the "From site" chip still works after other controls triggered a '
    'rebuild (regression: the chip used to sit behind a FutureBuilder '
    'whose Future was recreated on every setState, one Flutter anti-'
    'pattern independent of whether it ever visibly broke the chip)',
    (tester) async {
      const site = DiveSite(
        id: 'site-1',
        name: 'Test Site',
        location: GeoPoint(47.1, 8.3),
      );
      final repository = await _pump(
        tester,
        route: _route(siteId: 'site-1'),
        site: site,
      );

      // Trigger a handful of rebuilds via setState before using the chip.
      final sliderFinder = find.byKey(
        const ValueKey('nav-track-align-trust-slider'),
      );
      await tester.drag(sliderFinder, const Offset(20, 0));
      await tester.pump();
      await tester.drag(sliderFinder, const Offset(-10, 0));
      await tester.pump();

      final chipFinder = find.byKey(
        const ValueKey('nav-track-align-from-site'),
      );
      expect(chipFinder, findsOneWidget);
      await tester.tap(chipFinder);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('nav-track-align-save')));
      await tester.pumpAndSettle();

      expect(repository.lastCorrection?.anchor, const GeoPoint(47.1, 8.3));
    },
  );

  testWidgets('the end mode dropdown switches to "same as start"', (
    tester,
  ) async {
    final repository = await _pump(tester, route: _route());

    await tester.tap(find.byKey(const ValueKey('nav-track-align-end-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Same as start').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('nav-track-align-save')));
    await tester.pumpAndSettle();

    expect(repository.lastCorrection?.endMode, NavTrackEndMode.sameAsStart);
  });

  testWidgets(
    'dragging the trust slider updates the trust fraction and readout',
    (tester) async {
      final repository = await _pump(tester, route: _route());

      final sliderFinder = find.byKey(
        const ValueKey('nav-track-align-trust-slider'),
      );
      expect(sliderFinder, findsOneWidget);

      await tester.drag(sliderFinder, const Offset(80, 0));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('nav-track-align-save')));
      await tester.pumpAndSettle();

      expect(repository.lastCorrection?.trustFraction, greaterThan(0));
    },
  );

  testWidgets('moving the trust slider moves the trust marker on the route', (
    tester,
  ) async {
    await _pump(tester, route: _route());

    // Place the start marker so the route (and the trust marker) renders.
    await tester.tap(find.byKey(const ValueKey('nav-track-align-place-start')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('nav-track-align-set-here')));
    await tester.pump();

    final trustMarkerFinder = find.byKey(
      const ValueKey('nav-track-align-trust-marker'),
    );
    expect(trustMarkerFinder, findsOneWidget);
    final before = tester.getCenter(trustMarkerFinder);

    final sliderFinder = find.byKey(
      const ValueKey('nav-track-align-trust-slider'),
    );
    await tester.drag(sliderFinder, const Offset(150, 0));
    await tester.pump();

    final after = tester.getCenter(trustMarkerFinder);
    expect(after, isNot(before));
  });

  testWidgets('reset correction clears the anchor and end mode', (
    tester,
  ) async {
    final repository = await _pump(tester, route: _route());

    await tester.tap(find.byKey(const ValueKey('nav-track-align-place-start')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('nav-track-align-set-here')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('nav-track-align-reset')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('nav-track-align-save')));
    await tester.pumpAndSettle();

    expect(repository.lastCorrection?.anchor, isNull);
    expect(repository.lastCorrection?.endMode, NavTrackEndMode.none);
    expect(repository.lastCorrection?.trustFraction, 0);
  });

  testWidgets(
    'dragging the start marker right on screen moves it east, and down '
    'moves it south',
    (tester) async {
      final repository = await _pump(tester, route: _route());

      // Place the start marker at the map's initial centre first.
      await tester.tap(
        find.byKey(const ValueKey('nav-track-align-place-start')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('nav-track-align-set-here')));
      await tester.pump();

      final markerFinder = find.byKey(
        const ValueKey('nav-track-align-start-marker'),
      );
      expect(markerFinder, findsOneWidget);

      // Drag right and down on screen.
      await tester.drag(markerFinder, const Offset(40, 30));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('nav-track-align-save')));
      await tester.pumpAndSettle();

      const before = GeoPoint(0, 0);
      final after = repository.lastCorrection?.anchor;
      expect(after, isNotNull);
      // Right on screen must increase longitude (east); down must decrease
      // latitude (south). A north/east or sign mix-up would flip one or
      // both of these compass directions.
      expect(after!.longitude, greaterThan(before.longitude));
      expect(after.latitude, lessThan(before.latitude));
    },
  );

  testWidgets('cancel pops without saving', (tester) async {
    final repository = await _pump(tester, route: _route());

    await tester.tap(find.byKey(const ValueKey('nav-track-align-cancel')));
    await tester.pumpAndSettle();

    expect(repository.lastCorrection, isNull);
  });

  testWidgets(
    'typing a rotation value into the field updates headingOffsetDeg',
    (tester) async {
      final repository = await _pump(tester, route: _route());

      final fieldFinder = find.byKey(
        const ValueKey('nav-track-align-rotation-field'),
      );
      await tester.enterText(fieldFinder, '12.5');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('nav-track-align-save')));
      await tester.pumpAndSettle();

      expect(repository.lastCorrection?.headingOffsetDeg, 12.5);
    },
  );

  testWidgets(
    'entering garbage text into the rotation field leaves the prior value '
    'intact',
    (tester) async {
      final repository = await _pump(tester, route: _route());

      // Establish a known non-zero value first via the stepper.
      await tester.tap(find.byKey(const ValueKey('nav-track-align-rotate-up')));
      await tester.pump();

      final fieldFinder = find.byKey(
        const ValueKey('nav-track-align-rotation-field'),
      );
      await tester.enterText(fieldFinder, 'not a number');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('nav-track-align-save')));
      await tester.pumpAndSettle();

      expect(repository.lastCorrection?.headingOffsetDeg, 0.5);
    },
  );
}
