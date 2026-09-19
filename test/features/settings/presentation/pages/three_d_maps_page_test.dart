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

    expect(find.text('Reload Map Data'), findsOneWidget);
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

  testWidgets(
    'cancelling the confirm dialog does not run the clear action',
    (tester) async {
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
    },
  );
}
