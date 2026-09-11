import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_providers.dart';
import 'package:submersion/features/nav_track/domain/entities/nav_track.dart';
import 'package:submersion/features/nav_track/presentation/pages/nav_track_detail_page.dart';
import 'package:submersion/features/nav_track/presentation/providers/nav_track_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../../helpers/mock_providers.dart';

NavTrack _route({String? diveId}) => NavTrack(
  id: 'r1',
  diveId: diveId,
  linkMode: diveId == null ? null : NavTrackLinkMode.auto,
  source: NavTrackSource.seacraftEnc,
  sourceRef: 'r1.csv',
  startTime: 1755856800000,
  endTime: 1755860400000,
  pointCount: 0,
  createdAt: DateTime(2026, 8, 22),
  updatedAt: DateTime(2026, 8, 22),
);

Future<void> _pump(
  WidgetTester tester, {
  required NavTrack route,
  Dive? linkedDive,
}) async {
  final overrides = await getBaseOverrides();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...overrides,
        navTrackByIdProvider(route.id).overrideWith((ref) async => route),
        if (linkedDive != null)
          diveProvider(linkedDive.id).overrideWith((ref) async => linkedDive),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: NavTrackDetailPage(trackId: route.id),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows "No dive linked" for an unlinked route', (tester) async {
    await _pump(tester, route: _route());

    expect(find.byKey(const ValueKey('nav-track-no-dive')), findsOneWidget);
    expect(find.text('No dive linked'), findsOneWidget);
    expect(find.text('Choose dive'), findsOneWidget);
  });

  testWidgets('shows the linked dive for a linked route', (tester) async {
    final dive = Dive(
      id: 'dive-1',
      diveNumber: 412,
      dateTime: DateTime(2026, 8, 22, 10, 8),
    );
    await _pump(
      tester,
      route: _route(diveId: 'dive-1'),
      linkedDive: dive,
    );

    expect(find.byKey(const ValueKey('nav-track-linked-dive')), findsOneWidget);
    expect(find.textContaining('#412'), findsOneWidget);
  });

  testWidgets('shows the no-correction sentence when nothing was aligned', (
    tester,
  ) async {
    await _pump(tester, route: _route());

    expect(find.text('No correction applied yet.'), findsOneWidget);
  });
}
