// The reported symptom, at the widget: a file with no columns rendered the
// normal mapping editor, whose header reads "Column Mapping / 0 of 0 columns
// mapped" over an empty list. Nothing on screen said the import had failed.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/features/universal_import/data/models/detection_result.dart';
import 'package:submersion/features/universal_import/data/models/import_enums.dart';
import 'package:submersion/features/universal_import/data/models/import_options.dart';
import 'package:submersion/features/universal_import/presentation/providers/universal_import_providers.dart';
import 'package:submersion/features/universal_import/presentation/widgets/field_mapping_step.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: FieldMappingStep()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a file with no columns explains itself instead of "0 of 0"', (
    tester,
  ) async {
    final container = await _container();
    container.read(universalImportNotifierProvider.notifier).state = container
        .read(universalImportNotifierProvider)
        .copyWith(
          detectionResult: const DetectionResult(
            format: ImportFormat.uddf,
            confidence: 0.9,
          ),
          options: const ImportOptions(
            sourceApp: SourceApp.generic,
            format: ImportFormat.uddf,
          ),
          error: 'No data could be parsed from the file',
        );

    await _pump(tester, container);

    expect(find.textContaining('0 of 0 columns mapped'), findsNothing);
    expect(find.textContaining('no columns to map'), findsOneWidget);
    expect(find.text('No data could be parsed from the file'), findsOneWidget);
  });

  testWidgets('a CSV with columns still gets the mapping editor', (
    tester,
  ) async {
    final container = await _container();
    container.read(universalImportNotifierProvider.notifier).state = container
        .read(universalImportNotifierProvider)
        .copyWith(
          detectionResult: const DetectionResult(
            format: ImportFormat.csv,
            confidence: 0.9,
            csvHeaders: ['Date', 'Max Depth'],
          ),
          options: const ImportOptions(
            sourceApp: SourceApp.generic,
            format: ImportFormat.csv,
          ),
        );

    await _pump(tester, container);

    expect(find.text('Column Mapping'), findsOneWidget);
    expect(find.text('Date'), findsOneWidget);
    expect(find.text('Max Depth'), findsOneWidget);
  });
}
