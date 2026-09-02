// The Next button used to drop the future it started. Anything an acquisition
// step threw -- a parse, a database read the duplicate check made -- surfaced
// nowhere, so from the outside the button simply did nothing, however many
// times it was tapped (reported on ScubaBoard against v1.7.6).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/import_wizard/domain/adapters/import_source_adapter.dart';
import 'package:submersion/features/import_wizard/domain/models/duplicate_action.dart';
import 'package:submersion/features/import_wizard/domain/models/import_bundle.dart';
import 'package:submersion/features/import_wizard/domain/models/import_cancellation_token.dart';
import 'package:submersion/features/import_wizard/domain/models/import_phase.dart';
import 'package:submersion/features/import_wizard/domain/models/import_step_failure.dart';
import 'package:submersion/features/import_wizard/domain/models/unified_import_result.dart';
import 'package:submersion/features/import_wizard/presentation/pages/unified_import_wizard.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';
import 'package:submersion/shared/widgets/wizard/wizard_step_def.dart';

final _canAdvance = Provider<bool>((_) => true);

/// One acquisition step whose onBeforeAdvance fails the way a bad parse does.
class _FailingStepAdapter implements ImportSourceAdapter {
  _FailingStepAdapter({required this.onAdvance, this.duplicateCheck});

  final Future<void> Function() onAdvance;
  final Future<ImportBundle> Function(ImportBundle)? duplicateCheck;

  int buildBundleCalls = 0;
  ImportBundle? bundleGivenToWizard;

  @override
  void resetState() {}

  @override
  ImportSourceType get sourceType => ImportSourceType.uddf;

  @override
  String get displayName => 'Test Import';

  @override
  String get defaultTagName => 'Test Import';

  @override
  List<WizardStepDef> get acquisitionSteps => [
    WizardStepDef(
      label: 'Confirm Source',
      builder: (_) => const Center(child: Text('Step 1')),
      canAdvance: _canAdvance,
      onBeforeAdvance: onAdvance,
    ),
  ];

  @override
  Set<DuplicateAction> get supportedDuplicateActions => {DuplicateAction.skip};

  @override
  Set<DuplicateAction> duplicateActionsFor(ImportEntityType type) =>
      supportedDuplicateActions;

  @override
  Future<ImportBundle> buildBundle() async {
    buildBundleCalls++;
    return const ImportBundle(
      source: ImportSourceInfo(
        type: ImportSourceType.uddf,
        displayName: 'Test Import',
      ),
      groups: {},
    );
  }

  @override
  Future<ImportBundle> checkDuplicates(ImportBundle bundle) async {
    if (duplicateCheck != null) return duplicateCheck!(bundle);
    return bundle;
  }

  @override
  Future<UnifiedImportResult> performImport(
    ImportBundle bundle,
    Map<ImportEntityType, Set<int>> selections,
    Map<ImportEntityType, Map<int, DuplicateAction>> duplicateActions, {
    bool retainSourceDiveNumbers = false,
    ImportProgressCallback? onProgress,
    ImportCancellationToken? cancelToken,
  }) => throw UnimplementedError();
}

Widget _wizard(ImportSourceAdapter adapter) => ProviderScope(
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: UnifiedImportWizard(adapter: adapter),
  ),
);

Future<void> _tapNext(WidgetTester tester) async {
  await tester.tap(find.text('Next'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows an ImportStepFailure message instead of doing nothing', (
    tester,
  ) async {
    final adapter = _FailingStepAdapter(
      onAdvance: () async => throw const ImportStepFailure(
        'No data could be parsed from the file',
      ),
    );
    await tester.pumpWidget(_wizard(adapter));
    await tester.pumpAndSettle();

    await _tapNext(tester);

    expect(find.text('No data could be parsed from the file'), findsOneWidget);
    // Still on the acquisition step: a failed step must not advance.
    expect(find.text('Step 1'), findsOneWidget);
    expect(adapter.buildBundleCalls, 0);
  });

  testWidgets('shows a message when a step throws something unexpected', (
    tester,
  ) async {
    final adapter = _FailingStepAdapter(
      onAdvance: () async => throw StateError('Database not initialized'),
    );
    await tester.pumpWidget(_wizard(adapter));
    await tester.pumpAndSettle();

    await _tapNext(tester);

    expect(find.textContaining('Database not initialized'), findsOneWidget);
    expect(find.text('Step 1'), findsOneWidget);
  });

  testWidgets(
    'a failing duplicate check still reaches review, with a warning',
    (tester) async {
      final adapter = _FailingStepAdapter(
        onAdvance: () async {},
        duplicateCheck: (_) async => throw StateError('dedupe query blew up'),
      );
      await tester.pumpWidget(_wizard(adapter));
      await tester.pumpAndSettle();

      await _tapNext(tester);

      expect(adapter.buildBundleCalls, 1);
      expect(find.text('Step 1'), findsNothing);
      expect(
        find.textContaining('Duplicate detection could not run'),
        findsOneWidget,
      );
    },
  );
}
