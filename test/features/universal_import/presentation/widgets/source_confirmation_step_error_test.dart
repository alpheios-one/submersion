// Confirm Source is where the user is standing when a parse fails on the way
// out of it, so it is where the reason has to appear. Before this it rendered
// only the detection result and its warnings, never state.error, which is half
// of why the reported failure was silent.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/features/universal_import/data/models/detection_result.dart';
import 'package:submersion/features/universal_import/data/models/import_enums.dart';
import 'package:submersion/features/universal_import/presentation/providers/universal_import_providers.dart';
import 'package:submersion/features/universal_import/presentation/widgets/source_confirmation_step.dart';
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
        // flutter_test forwards the host machine's locale list rather than a
        // fixed en_US, and the app ships 11 locales, so an unpinned
        // MaterialApp renders translated on a non-English machine.
        locale: Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SourceConfirmationStep()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _detection = DetectionResult(
  format: ImportFormat.uddf,
  sourceApp: SourceApp.subsurface,
  confidence: 0.95,
);

void main() {
  testWidgets('shows the reason a parse failed', (tester) async {
    final container = await _container();
    container.read(universalImportNotifierProvider.notifier).state = container
        .read(universalImportNotifierProvider)
        .copyWith(
          detectionResult: _detection,
          error: 'No data could be parsed from the file',
        );

    await _pump(tester, container);

    expect(find.text('No data could be parsed from the file'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });

  testWidgets('shows no error banner when nothing has failed', (tester) async {
    final container = await _container();
    container.read(universalImportNotifierProvider.notifier).state = container
        .read(universalImportNotifierProvider)
        .copyWith(detectionResult: _detection);

    await _pump(tester, container);

    expect(find.byIcon(Icons.error_outline), findsNothing);
    // The step still does its own job.
    expect(find.textContaining(_detection.description), findsWidgets);
  });
}
