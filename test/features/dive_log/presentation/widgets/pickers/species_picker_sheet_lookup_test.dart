import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_log/presentation/widgets/pickers/species_picker_sheet.dart';
import 'package:submersion/features/marine_life/data/repositories/species_repository.dart';
import 'package:submersion/features/marine_life/data/services/species_lookup_service.dart';
import 'package:submersion/features/marine_life/domain/entities/species.dart';
import 'package:submersion/features/marine_life/domain/entities/species_lookup.dart';
import 'package:submersion/features/marine_life/presentation/providers/species_lookup_providers.dart';
import 'package:submersion/features/marine_life/presentation/providers/species_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

const _hit = SpeciesLookupHit(
  taxonId: 52188,
  scientificName: 'Rhincodon typus',
  rank: 'species',
  rankLevel: 10,
  commonName: 'Whale Shark',
  observationCount: 5,
);

const _resolved = SpeciesLookupResult(
  taxonId: 52188,
  commonName: 'Whale Shark',
  scientificName: 'Rhincodon typus',
  category: SpeciesCategory.shark,
  taxonomyClass: 'Chondrichthyes',
);

class _FakeLookup implements SpeciesLookupService {
  @override
  Future<List<SpeciesLookupHit>> search(
    String query, {
    required String locale,
  }) async => const [_hit];

  @override
  Future<SpeciesLookupResult> resolve(
    int taxonId, {
    required String locale,
  }) async => _resolved;
}

/// Records creations; `existing` is what a scientific-name lookup returns.
class _RecordingRepository extends Fake implements SpeciesRepository {
  _RecordingRepository({this.existing});

  final Species? existing;
  final List<Map<String, Object?>> created = [];
  int nameOnlyCreations = 0;

  @override
  Future<Species?> findSpeciesByScientificName(String scientificName) async =>
      existing;

  @override
  Future<Species> createSpecies({
    required String commonName,
    String? scientificName,
    required SpeciesCategory category,
    String? taxonomyClass,
    String? description,
  }) async {
    created.add({
      'commonName': commonName,
      'scientificName': scientificName,
      'category': category,
      'taxonomyClass': taxonomyClass,
    });
    return Species(
      id: 'new-1',
      commonName: commonName,
      scientificName: scientificName,
      category: category,
      taxonomyClass: taxonomyClass,
    );
  }

  @override
  Future<Species> getOrCreateSpecies({
    required String commonName,
    String? scientificName,
    required SpeciesCategory category,
  }) async {
    nameOnlyCreations += 1;
    return Species(id: 'plain-1', commonName: commonName, category: category);
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required _RecordingRepository repository,
}) async {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        allSpeciesProvider.overrideWith((ref) async => const []),
        speciesByCategoryProvider.overrideWith(
          (ref, category) async => const [],
        ),
        speciesSearchProvider.overrideWith((ref, query) async => const []),
        speciesRepositoryProvider.overrideWithValue(repository),
        speciesLookupServiceProvider.overrideWithValue(_FakeLookup()),
        speciesLookupLocaleProvider.overrideWithValue('en'),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SpeciesPickerSheet(
            scrollController: ScrollController(),
            onSpeciesSelected: (_, _, _) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _typeAndAdd(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField).first, 'whale');
  await tester.pumpAndSettle();
  await tester.tap(find.textContaining('whale').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a lookup result creates the species with its fields and '
      'opens the sighting dialog', (tester) async {
    final repository = _RecordingRepository();
    await _pump(tester, repository: repository);

    await _typeAndAdd(tester);
    await tester.tap(find.text('Look up'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Whale Shark'));
    await tester.pumpAndSettle();

    expect(repository.created.single['scientificName'], 'Rhincodon typus');
    expect(repository.created.single['category'], SpeciesCategory.shark);
    expect(repository.created.single['taxonomyClass'], 'Chondrichthyes');
    expect(repository.nameOnlyCreations, 0);
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('an existing species with that scientific name is reused', (
    tester,
  ) async {
    const existing = Species(
      id: 'sp_whale_shark',
      commonName: 'Whale Shark',
      scientificName: 'Rhincodon typus',
      category: SpeciesCategory.shark,
      isBuiltIn: true,
    );
    final repository = _RecordingRepository(existing: existing);
    await _pump(tester, repository: repository);

    await _typeAndAdd(tester);
    await tester.tap(find.text('Look up'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Whale Shark'));
    await tester.pumpAndSettle();

    expect(repository.created, isEmpty);
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('Create without lookup keeps the name-only path', (tester) async {
    final repository = _RecordingRepository();
    await _pump(tester, repository: repository);

    await _typeAndAdd(tester);
    await tester.tap(find.text('Create without lookup'));
    await tester.pumpAndSettle();

    expect(repository.nameOnlyCreations, 1);
    expect(repository.created, isEmpty);
    expect(find.byType(AlertDialog), findsOneWidget);
  });
}
