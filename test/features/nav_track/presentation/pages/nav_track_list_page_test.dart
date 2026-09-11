import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_providers.dart';
import 'package:submersion/features/nav_track/domain/entities/nav_track.dart';
import 'package:submersion/features/nav_track/presentation/pages/nav_track_list_page.dart';
import 'package:submersion/features/nav_track/presentation/providers/nav_track_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../../helpers/mock_providers.dart';

NavTrack _route({
  required String id,
  String? diveId,
  String? name,
  String? deviceName,
  double? distance,
  double? maxDepth,
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
  createdAt: DateTime(2026, 8, 22),
  updatedAt: DateTime(2026, 8, 22),
);

Future<void> _pump(
  WidgetTester tester, {
  required List<NavTrack> routes,
  Dive? linkedDive,
}) async {
  final overrides = await getBaseOverrides();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...overrides,
        allNavTracksProvider.overrideWith((ref) async => routes),
        if (linkedDive != null)
          diveProvider(linkedDive.id).overrideWith((ref) async => linkedDive),
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
}
