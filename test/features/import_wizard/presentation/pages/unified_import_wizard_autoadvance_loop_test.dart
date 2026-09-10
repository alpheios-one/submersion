// An auto-advancing step whose work fails must not retry itself forever.
//
// _AcquisitionStepPage arms auto-advance on every build where its page is
// current and canAutoAdvance reads true. Reporting a failure is itself a
// setState, so a failing auto-advance step would re-arm on the rebuild its own
// error message caused: fail, rebuild, fail, with the parse re-running each
// time and the Next button never reachable.

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

/// Always ready to auto-advance, the way Map Fields is for a preset-detected
/// CSV whose mapping was filled in for the user.
final _alwaysReady = Provider<bool>((_) => true);

class _AutoAdvancingFailureAdapter implements ImportSourceAdapter {
  int advanceAttempts = 0;

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
      label: 'Map Fields',
      builder: (_) => const Center(child: Text('Step 1')),
      canAdvance: _alwaysReady,
      autoAdvance: true,
      onBeforeAdvance: () async {
        advanceAttempts++;
        throw const ImportStepFailure('No data could be parsed from the file');
      },
    ),
  ];

  @override
  Set<DuplicateAction> get supportedDuplicateActions => {DuplicateAction.skip};

  @override
  Set<DuplicateAction> duplicateActionsFor(ImportEntityType type) =>
      supportedDuplicateActions;

  @override
  Future<ImportBundle> buildBundle() async => const ImportBundle(
    source: ImportSourceInfo(
      type: ImportSourceType.uddf,
      displayName: 'Test Import',
    ),
    groups: {},
  );

  @override
  Future<ImportBundle> checkDuplicates(ImportBundle bundle) async => bundle;

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

void main() {
  testWidgets('a failing auto-advance step stops after one attempt', (
    tester,
  ) async {
    final adapter = _AutoAdvancingFailureAdapter();

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: UnifiedImportWizard(adapter: adapter),
        ),
      ),
    );

    // Deliberately not pumpAndSettle: with the step re-arming itself there is
    // nothing to settle to, and this would time out instead of reporting the
    // count. Pump plenty of frames and count the attempts.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(
      adapter.advanceAttempts,
      1,
      reason: 'the step re-ran itself ${adapter.advanceAttempts} times',
    );
    expect(find.text('No data could be parsed from the file'), findsOneWidget);
    expect(find.text('Step 1'), findsOneWidget);

    // Stopping the loop must not wedge the step: a deliberate tap still
    // retries, and still costs exactly one attempt.
    await tester.tap(find.text('Next'));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(adapter.advanceAttempts, 2);
    expect(find.text('No data could be parsed from the file'), findsOneWidget);
  });
}
