import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:submersion/core/constants/units.dart';
import 'package:submersion/features/dive_sites/domain/entities/site_feature.dart';
import 'package:submersion/features/dive_sites/presentation/providers/site_feature_providers.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/features/site_scape/presentation/site_features_section.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../helpers/mock_providers.dart';

const _features = [
  SiteFeature(
    id: 'f-1',
    siteId: 'site-1',
    typeName: 'mooring',
    latitude: 12.15,
    longitude: -68.3,
    depthMeters: 6,
  ),
  SiteFeature(
    id: 'f-2',
    siteId: 'site-1',
    typeName: 'wreck',
    name: 'Hilma Hooker',
    latitude: 12.16,
    longitude: -68.31,
  ),
];

Future<int> _pumpSection(
  WidgetTester tester, {
  AppSettings settings = const AppSettings(),
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  var addTaps = 0;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        settingsProvider.overrideWith((ref) => MockSettingsNotifier(settings)),
        siteFeaturesProvider('site-1').overrideWith((ref) async => _features),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SiteFeaturesSection(
            siteId: 'site-1',
            onAddFeature: () => addTaps++,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return addTaps;
}

void main() {
  testWidgets('lists features with type labels and depth in display units', (
    tester,
  ) async {
    await _pumpSection(tester);

    // A named feature shows its name; an unnamed one falls back to the
    // type label.
    expect(find.text('Hilma Hooker'), findsOneWidget);
    expect(find.text('Mooring'), findsOneWidget);
    // Depth rides the subtitle in the diver's unit.
    expect(find.textContaining('6 m'), findsOneWidget);
  });

  testWidgets('a feet diver reads depths in feet', (tester) async {
    await _pumpSection(
      tester,
      settings: const AppSettings(depthUnit: DepthUnit.feet),
    );
    // 6 m is 19.7 ft.
    expect(find.textContaining('19.7 ft'), findsOneWidget);
  });

  testWidgets('the add action hands control back to the host', (tester) async {
    await _pumpSection(tester);
    await tester.tap(find.byKey(const ValueKey('siteFeatureAddButton')));
    await tester.pump();
    // The section itself never places: the host opens the map.
    expect(find.byKey(const ValueKey('siteFeatureSaveButton')), findsNothing);
  });

  testWidgets('tapping a row opens the edit sheet', (tester) async {
    await _pumpSection(tester);
    await tester.tap(find.byKey(const ValueKey('siteFeatureRow-f-2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('siteFeatureSaveButton')), findsOneWidget);
    expect(find.text('Edit feature'), findsOneWidget);
  });
}
