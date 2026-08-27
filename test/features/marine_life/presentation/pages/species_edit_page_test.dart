import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/features/marine_life/data/services/species_lookup_service.dart';
import 'package:submersion/features/marine_life/domain/entities/species_lookup.dart';
import 'package:submersion/features/marine_life/presentation/pages/species_edit_page.dart';
import 'package:submersion/features/marine_life/presentation/providers/species_lookup_providers.dart';

import '../../../../helpers/test_app.dart';

class _FakeLookup implements SpeciesLookupService {
  @override
  Future<List<SpeciesLookupHit>> search(
    String query, {
    required String locale,
  }) async => const [
    SpeciesLookupHit(
      taxonId: 52188,
      scientificName: 'Rhincodon typus',
      rank: 'species',
      rankLevel: 10,
      commonName: 'Whale Shark',
      observationCount: 5,
    ),
  ];

  @override
  Future<SpeciesLookupResult> resolve(
    int taxonId, {
    required String locale,
  }) async => const SpeciesLookupResult(
    taxonId: 52188,
    commonName: 'Whale Shark',
    scientificName: 'Rhincodon typus',
    category: SpeciesCategory.shark,
    taxonomyClass: 'Chondrichthyes',
  );
}

void main() {
  testWidgets('a lookup fills name, scientific name, category and class', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(
        locale: const Locale('en'),
        overrides: [
          speciesLookupServiceProvider.overrideWithValue(_FakeLookup()),
          speciesLookupLocaleProvider.overrideWithValue('en'),
        ],
        child: const SpeciesEditPage(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, 'whale');
    await tester.tap(find.text('Look up online'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Look up'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Whale Shark'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextFormField, 'Whale Shark'), findsOneWidget);
    expect(
      find.widgetWithText(TextFormField, 'Rhincodon typus'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(TextFormField, 'Chondrichthyes'),
      findsOneWidget,
    );
    expect(find.text('Shark'), findsOneWidget);
  });
}
