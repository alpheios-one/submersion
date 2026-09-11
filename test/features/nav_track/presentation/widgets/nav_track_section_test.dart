import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_detail_ui_providers.dart';
import 'package:submersion/features/nav_track/domain/entities/nav_track.dart';
import 'package:submersion/features/nav_track/presentation/providers/nav_track_providers.dart';
import 'package:submersion/features/nav_track/presentation/widgets/nav_track_section.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../../helpers/mock_providers.dart';

final _dive = Dive(
  id: 'dive-1',
  diveNumber: 1,
  dateTime: DateTime(2026, 8, 22),
);

NavTrack _route({String? diveId}) => NavTrack(
  id: 'r1',
  diveId: diveId,
  isPrimary: true,
  source: NavTrackSource.seacraftEnc,
  sourceRef: 'r1.csv',
  startTime: 1755856800000,
  endTime: 1755860400000,
  pointCount: 0,
  totalDistance: 1050,
  maxDepth: 38,
  createdAt: DateTime(2026, 8, 22),
  updatedAt: DateTime(2026, 8, 22),
);

Future<void> _pump(
  WidgetTester tester, {
  required List<NavTrack> linkedRoutes,
  List<NavTrack> unlinkedRoutes = const [],
}) async {
  final overrides = await getBaseOverrides();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...overrides,
        navTrackSectionExpandedProvider.overrideWith((ref) => true),
        navTracksForDiveProvider(
          _dive.id,
        ).overrideWith((ref) async => linkedRoutes),
        unlinkedNavTracksProvider.overrideWith((ref) async => unlinkedRoutes),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: NavTrackSection(dive: _dive)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('empty state offers Link route and Import file', (tester) async {
    await _pump(tester, linkedRoutes: const [], unlinkedRoutes: [_route()]);

    expect(find.text('No route linked'), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-track-link-button')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('nav-track-import-button')),
      findsOneWidget,
    );
  });

  testWidgets('empty state hides Link route when nothing is unlinked', (
    tester,
  ) async {
    await _pump(tester, linkedRoutes: const [], unlinkedRoutes: const []);

    expect(find.byKey(const ValueKey('nav-track-link-button')), findsNothing);
    expect(
      find.byKey(const ValueKey('nav-track-import-button')),
      findsOneWidget,
    );
  });

  testWidgets('populated state shows one row per linked route', (tester) async {
    await _pump(tester, linkedRoutes: [_route(diveId: _dive.id)]);

    expect(find.text('No route linked'), findsNothing);
    expect(find.byKey(const ValueKey('nav-track-row-r1')), findsOneWidget);
    expect(find.textContaining('primary'), findsOneWidget);
  });

  testWidgets(
    'shows the route\'s own stored distance and depth, not zero (proactive '
    'finding: navTracksForDiveProvider reads with includePoints: false, '
    'same as the routes-area list before item 9 was fixed -- recomputing '
    'NavTrackStats.of the empty points list silently zeroed the row)',
    (tester) async {
      await _pump(tester, linkedRoutes: [_route(diveId: _dive.id)]);

      expect(find.textContaining('1050'), findsOneWidget);
      expect(find.textContaining('38'), findsOneWidget);
    },
  );
}
