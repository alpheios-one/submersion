import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:submersion/features/dive_sites/domain/entities/site_feature.dart';
import 'package:submersion/features/dive_sites/presentation/providers/site_feature_providers.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/features/site_scape/presentation/site_feature_marker_layer.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../helpers/mock_providers.dart';

const _feature = SiteFeature(
  id: 'f-1',
  siteId: 'site-1',
  typeName: 'current',
  name: 'Ebb runs north',
  latitude: 12.15,
  longitude: -68.3,
  bearingDeg: 90,
);

Future<void> _pumpMap(
  WidgetTester tester, {
  required String? siteId,
  List<SiteFeature> features = const [_feature],
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        settingsProvider.overrideWith(
          (ref) => MockSettingsNotifier(const AppSettings()),
        ),
        siteFeaturesProvider('site-1').overrideWith((ref) async => features),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: FlutterMap(
            options: const MapOptions(
              initialCenter: LatLng(12.15, -68.3),
              initialZoom: 14,
            ),
            children: [SiteFeatureMarkerLayer(siteId: siteId)],
          ),
        ),
      ),
    ),
  );
  // Bounded pumps: flutter_map never settles under flutter_test.
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('renders one rotated marker per feature and edits on tap', (
    tester,
  ) async {
    await _pumpMap(tester, siteId: 'site-1');

    final marker = find.byKey(const ValueKey('siteFeatureMarker-f-1'));
    expect(marker, findsOneWidget);
    // A bearing of 90 degrees rotates the glyph a quarter turn.
    final rotate = tester.widget<Transform>(
      find.descendant(of: marker, matching: find.byType(Transform)).first,
    );
    expect(rotate.transform.storage[0], closeTo(math.cos(math.pi / 2), 1e-9));

    await tester.tap(marker);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // The shared edit sheet opened for this feature.
    expect(find.byKey(const ValueKey('siteFeatureSaveButton')), findsOneWidget);
  });

  testWidgets('null siteId renders nothing', (tester) async {
    await _pumpMap(tester, siteId: null);
    expect(find.byKey(const ValueKey('siteFeatureMarker-f-1')), findsNothing);
  });

  testWidgets('an empty feature list renders nothing', (tester) async {
    await _pumpMap(tester, siteId: 'site-1', features: const []);
    expect(find.byKey(const ValueKey('siteFeatureMarker-f-1')), findsNothing);
  });
}
