import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/features/dive_log/data/repositories/dive_repository_impl.dart';
import 'package:submersion/features/dive_log/data/services/dive_consolidation_service.dart';
import 'package:submersion/features/dive_log/data/services/dive_merge_snapshot.dart';
import 'package:submersion/features/dive_log/presentation/widgets/run_dive_consolidation.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

/// Covers `runDiveConsolidation` -- the shared apply/undo/SnackBar wiring
/// behind the multi-select combine dialog's consolidation panel -- directly,
/// without a dialog in front of it.
///
/// The success path is also exercised end-to-end through
/// combine_dives_dialog_test.dart; the undo and failure branches are only
/// reachable here, so this file owns them. (They used to ride along on
/// merge_dive_dialog_test.dart, whose widget was orphaned and removed in
/// #1452.)
void main() {
  group('runDiveConsolidation', () {
    testWidgets(
      'calls DiveConsolidationService.apply with the target and secondaries',
      (tester) async {
        final service = _FakeDiveConsolidationService();

        await _pumpAndRun(tester, service: service);

        expect(service.capturedTargetDiveId, equals('target-dive'));
        expect(service.capturedSecondaryDiveIds, equals(['secondary-dive']));
      },
    );

    testWidgets('reports the fold to the caller via onConsolidated', (
      tester,
    ) async {
      var consolidatedCalls = 0;

      await _pumpAndRun(
        tester,
        service: _FakeDiveConsolidationService(),
        onConsolidated: () => consolidatedCalls++,
      );

      expect(consolidatedCalls, 1);
    });

    testWidgets('shows an Undo snackbar on success with persist:false and '
        "showCloseIcon:true (this repo's convention for actioned SnackBars)", (
      tester,
    ) async {
      await _pumpAndRun(tester, service: _FakeDiveConsolidationService());

      final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(snackBar.action, isNotNull);
      expect(snackBar.action!.label, equals('Undo'));
      expect(snackBar.persist, isFalse);
      expect(snackBar.showCloseIcon, isTrue);
    });

    testWidgets('tapping Undo calls service.undo with the outcome snapshot', (
      tester,
    ) async {
      final service = _FakeDiveConsolidationService();

      await _pumpAndRun(tester, service: service);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(service.undoneSnapshot, isNotNull);
      expect(identical(service.undoneSnapshot, service.outcomeSnapshot), true);
    });

    testWidgets(
      'tapping Undo when service.undo throws shows the undo-error snackbar '
      'text instead of crashing',
      (tester) async {
        final service = _FakeDiveConsolidationService(
          undoError: StateError('Bad state: dive already deleted'),
        );

        await _pumpAndRun(tester, service: service);

        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();

        // See app_en.arb's diveLog_consolidate_undoError for the English
        // source string.
        expect(find.text("Couldn't undo the merge."), findsOneWidget);
        // The undo attempt was made (and failed) rather than silently
        // skipped -- undoneSnapshot stays unset because the throw happens
        // before it would be recorded.
        expect(service.undoneSnapshot, isNull);
        // The failure was caught inside the SnackBarAction's onPressed; no
        // exception should escape to the test framework.
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'an ArgumentError with a sameComputer reason surfaces the sameComputer '
      'error text instead of a success snackbar',
      (tester) async {
        await _pumpAndRun(
          tester,
          service: _FakeDiveConsolidationService(
            applyError: ArgumentError('sameComputer: shares comp-1'),
          ),
        );

        expect(
          find.text(
            "These dives are from the same dive computer and can't be "
            'merged this way.',
          ),
          findsOneWidget,
        );
        // No Undo action on a failure snackbar.
        final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
        expect(snackBar.action, isNull);
      },
    );

    testWidgets('an ArgumentError with a notOverlapping reason surfaces the '
        'notOverlapping error text', (tester) async {
      await _pumpAndRun(
        tester,
        service: _FakeDiveConsolidationService(
          // The wrapper DiveConsolidationBuilder.build throws.
          applyError: ArgumentError(
            'build() requires a consolidatable selection; got '
            'ConsolidationInvalid(notOverlapping)',
          ),
        ),
      );

      expect(
        find.text(
          "These dives don't overlap in time, so they can't be merged as "
          'the same dive.',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'a non-ArgumentError failure (e.g. a dive deleted by sync mid-flow) '
      'surfaces the generic error text instead of crashing',
      (tester) async {
        var consolidatedCalls = 0;

        await _pumpAndRun(
          tester,
          service: _FakeDiveConsolidationService(
            applyError: StateError('Bad state: No element'),
          ),
          onConsolidated: () => consolidatedCalls++,
        );

        expect(
          find.text("Couldn't merge the dives. Nothing was changed."),
          findsOneWidget,
        );
        final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
        expect(snackBar.action, isNull);
        // Nothing was written, so the caller is never told to refresh.
        expect(consolidatedCalls, 0);
        // The interaction failed gracefully: no unhandled exception reached
        // the framework.
        expect(tester.takeException(), isNull);
      },
    );
  });
}

/// Pumps a bare button whose callback invokes [runDiveConsolidation], taps it,
/// and settles. The helper needs nothing but a [BuildContext] with a
/// [ScaffoldMessenger] and localizations above it, so there is no dialog in
/// the way of the wiring under test.
Future<void> _pumpAndRun(
  WidgetTester tester, {
  required _FakeDiveConsolidationService service,
  String targetDiveId = 'target-dive',
  List<String> secondaryDiveIds = const ['secondary-dive'],
  VoidCallback? onConsolidated,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => runDiveConsolidation(
              context: context,
              service: service,
              targetDiveId: targetDiveId,
              secondaryDiveIds: secondaryDiveIds,
              onConsolidated: onConsolidated ?? () {},
            ),
            child: const Text('Merge'),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('Merge'));
  await tester.pumpAndSettle();
}

/// Records calls made to [DiveConsolidationService.apply] and [.undo] so
/// tests can assert on the wiring contract without touching a real database.
class _FakeDiveConsolidationService extends DiveConsolidationService {
  _FakeDiveConsolidationService({this.applyError, this.undoError})
    : super(DiveRepository());

  /// When set, [apply] throws this instead of returning a fake outcome.
  final Object? applyError;

  /// When set, [undo] throws this instead of recording the snapshot.
  final Object? undoError;

  String? capturedTargetDiveId;
  List<String>? capturedSecondaryDiveIds;
  DiveMergeSnapshot? undoneSnapshot;

  /// The snapshot handed back inside [apply]'s outcome -- exposed so tests
  /// can assert Undo is invoked with this exact instance.
  final DiveMergeSnapshot outcomeSnapshot = const DiveMergeSnapshot(
    mergedDiveId: 'target-dive',
    diveRows: [],
    tankRows: [],
    weightRows: [],
    customFieldRows: [],
    equipmentRows: [],
    diveTypeRows: [],
    tagRows: [],
    buddyRows: [],
    sightingRows: [],
    eventRows: [],
    gasSwitchRows: [],
    dataSourceRows: [],
    tideRows: [],
    mediaDiveIds: {},
  );

  @override
  Future<DiveConsolidationOutcome> apply({
    required String targetDiveId,
    required List<String> secondaryDiveIds,
  }) async {
    capturedTargetDiveId = targetDiveId;
    capturedSecondaryDiveIds = secondaryDiveIds;
    final error = applyError;
    if (error != null) throw error;
    return DiveConsolidationOutcome(
      targetDiveId: targetDiveId,
      snapshot: outcomeSnapshot,
    );
  }

  @override
  Future<void> undo(DiveMergeSnapshot snapshot) async {
    final error = undoError;
    if (error != null) throw error;
    undoneSnapshot = snapshot;
  }
}
