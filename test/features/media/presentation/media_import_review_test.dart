import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/media/domain/entities/import_candidate.dart';
import 'package:submersion/features/media/domain/services/dive_photo_matcher.dart';
import 'package:submersion/features/media/domain/value_objects/media_attach_target.dart';
import 'package:submersion/features/media/presentation/pages/media_import_review_page.dart';
import 'package:submersion/features/media/presentation/providers/media_import_suggestion_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

final t1 = DateTime.utc(2026, 6, 12, 10);
final t2 = DateTime.utc(2026, 6, 12, 11);
final t3 = DateTime.utc(2026, 6, 13, 10);

ImportSuggestion confident(String diveId, int number) => ImportSuggestion(
  match: TimestampMatch(kind: TimestampMatchKind.confident, diveId: diveId),
  diveNumber: number,
);

const none = ImportSuggestion(
  match: TimestampMatch(kind: TimestampMatchKind.none),
);

const ambiguous = ImportSuggestion(
  match: TimestampMatch(
    kind: TimestampMatchKind.ambiguous,
    candidateDiveIds: ['d1', 'd2'],
  ),
);

void main() {
  Map<String, MediaAttachTarget>? confirmed;

  Widget host(
    List<ImportCandidate> candidates,
    Map<DateTime, ImportSuggestion> suggestions,
  ) {
    confirmed = null;
    return ProviderScope(
      overrides: [
        for (final MapEntry(:key, :value) in suggestions.entries)
          importSuggestionProvider(key).overrideWith((ref) async => value),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaImportReviewPage(
          candidates: candidates,
          onConfirm: (targets) async {
            confirmed = targets;
            return ImportReviewResult(
              linked: targets.length,
              skipped: candidates.length - targets.length,
            );
          },
        ),
      ),
    );
  }

  ImportCandidate candidate(String key, DateTime? takenAt, {String? error}) =>
      ImportCandidate(
        key: key,
        title: '$key.jpg',
        takenAt: takenAt,
        error: error,
      );

  testWidgets('confident matches are pre-checked; the rest are not', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        [candidate('a', t1), candidate('b', t2), candidate('c', t3)],
        {t1: confident('d7', 7), t2: ambiguous, t3: none},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Link to #7'), findsOneWidget);
    expect(find.text('Several dives match'), findsOneWidget);
    expect(find.text('No matching dive'), findsOneWidget);
    expect(find.text('Import 1 items'), findsOneWidget);
  });

  testWidgets('confirm hands only resolved candidates to onConfirm', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        [candidate('a', t1), candidate('b', t3)],
        {t1: confident('d7', 7), t3: none},
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Import 1 items'));
    // Plain pumps: settling would run the snackbar's auto-dismiss to the
    // end before the assertion ever saw it.
    await tester.pump();
    await tester.pump();

    expect(confirmed, {'a': const DiveAttachTarget('d7')});
    expect(find.text('1 linked, 1 skipped, 0 failed'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('unchecking a confident row skips it', (tester) async {
    await tester.pumpWidget(
      host(
        [candidate('a', t1), candidate('b', t2)],
        {t1: confident('d7', 7), t2: confident('d8', 8)},
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('a.jpg'));
    await tester.pumpAndSettle();
    expect(find.text('Not imported'), findsOneWidget);
    expect(find.text('Import 1 items'), findsOneWidget);

    await tester.tap(find.text('Import 1 items'));
    await tester.pumpAndSettle();
    expect(confirmed, {'b': const DiveAttachTarget('d8')});
  });

  testWidgets('a failed candidate shows its error and is not imported', (
    tester,
  ) async {
    await tester.pumpWidget(
      host([candidate('a', null, error: 'HTTP 404')], const {}),
    );
    await tester.pumpAndSettle();

    expect(find.text('HTTP 404'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('nothing resolved disables confirm', (tester) async {
    await tester.pumpWidget(host([candidate('a', t3)], {t3: none}));
    await tester.pumpAndSettle();
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
    expect(confirmed, isNull);
  });
}
