import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/bathymetry/application/bathymetry_providers.dart';
import 'package:submersion/features/bathymetry/application/bathymetry_reset_providers.dart';
import 'package:submersion/features/settings/presentation/pages/three_d_maps_page.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../../helpers/mock_providers.dart';

void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    required List<Override> extraOverrides,
  }) async {
    final base = await getBaseOverrides();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [...base, ...extraOverrides],
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ThreeDMapsPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('renders all four actions', (tester) async {
    await pumpPage(
      tester,
      extraOverrides: [
        bathymetryRepositoryProvider.overrideWithValue(null),
        swissBathyTileCacheRepositoryProvider.overrideWithValue(null),
        knownDiveSiteLocationsProvider.overrideWith((ref) async => const []),
      ],
    );

    expect(find.text('Update Existing Map Data'), findsOneWidget);
    expect(find.text('Delete data'), findsOneWidget);
    expect(find.text('Reset remaining bathymetry data'), findsOneWidget);
    expect(find.text('Reload map data'), findsOneWidget);
  });

  testWidgets(
    'confirming the swissBATHY3D delete action calls the clear provider '
    'and shows a confirmation snackbar',
    (tester) async {
      var cleared = false;
      await pumpPage(
        tester,
        extraOverrides: [
          bathymetryRepositoryProvider.overrideWithValue(null),
          swissBathyTileCacheRepositoryProvider.overrideWithValue(null),
          knownDiveSiteLocationsProvider.overrideWith((ref) async => const []),
          swissBathyClearProvider.overrideWithValue(() async {
            cleared = true;
          }),
        ],
      );

      await tester.tap(find.text('Delete data'));
      await tester.pumpAndSettle();

      // The confirm dialog is up; nothing has run yet.
      expect(cleared, isFalse);
      expect(find.text('Delete swissBATHY3D data?'), findsOneWidget);

      await tester.tap(find.text('Delete data').last);
      await tester.pumpAndSettle();

      expect(cleared, isTrue);
      expect(find.text('swissBATHY3D data deleted'), findsOneWidget);
    },
  );

  testWidgets('cancelling the confirm dialog does not run the clear action', (
    tester,
  ) async {
    var cleared = false;
    await pumpPage(
      tester,
      extraOverrides: [
        bathymetryRepositoryProvider.overrideWithValue(null),
        swissBathyTileCacheRepositoryProvider.overrideWithValue(null),
        knownDiveSiteLocationsProvider.overrideWith((ref) async => const []),
        bathymetryOtherSourcesClearProvider.overrideWithValue(() async {
          cleared = true;
        }),
      ],
    );

    await tester.tap(find.text('Reset remaining bathymetry data').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(cleared, isFalse);
  });

  testWidgets(
    'the refresh tile is disabled while a delete/reset action is running '
    '(regression: a shared busy flag used to leave it tappable, letting it '
    'start concurrently with the delete)',
    (tester) async {
      final clearStarted = Completer<void>();
      final clearGate = Completer<void>();
      var refreshCalls = 0;
      await pumpPage(
        tester,
        extraOverrides: [
          bathymetryRepositoryProvider.overrideWithValue(null),
          swissBathyTileCacheRepositoryProvider.overrideWithValue(null),
          knownDiveSiteLocationsProvider.overrideWith((ref) async => const []),
          swissBathyClearProvider.overrideWithValue(() async {
            clearStarted.complete();
            await clearGate.future;
          }),
          swissBathyManualRefreshProvider.overrideWithValue(() async {
            refreshCalls++;
            return null;
          }),
        ],
      );

      await tester.tap(find.text('Delete data'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete data').last);
      await tester.pump();
      await clearStarted.future;
      await tester.pump();

      // The delete is now in flight. Tapping the refresh tile must do
      // nothing: IgnorePointer should be blocking it, not just dimming it --
      // the tap is expected to miss its target entirely, which is exactly
      // what warnIfMissed: false is here to confirm without flagging it as
      // a test-authoring mistake.
      await tester.tap(
        find.text('Update Existing Map Data'),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(refreshCalls, 0);

      clearGate.complete();
      await tester.pumpAndSettle();
    },
  );
}
