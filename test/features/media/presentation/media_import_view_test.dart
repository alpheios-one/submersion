import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/media/data/services/photo_picker_service.dart';
import 'package:submersion/features/media/domain/services/dive_photo_matcher.dart';
import 'package:submersion/features/media/presentation/pages/media_import_review_page.dart';
import 'package:submersion/features/media/presentation/pages/media_import_view.dart';
import 'package:submersion/features/media/presentation/providers/media_import_suggestion_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

AssetInfo asset(String id) => AssetInfo(
  id: id,
  type: AssetType.image,
  createDateTime: DateTime(2026, 6, 12, 10),
  width: 100,
  height: 100,
  filename: '$id.jpg',
);

void main() {
  Widget host({
    Future<List<AssetInfo>> Function(BuildContext)? launchOverride,
  }) {
    return ProviderScope(
      overrides: [
        importSuggestionProvider(DateTime.utc(2026, 6, 12, 10)).overrideWith(
          (ref) async => const ImportSuggestion(
            match: TimestampMatch(kind: TimestampMatchKind.none),
          ),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: MediaImportView(launchOverride: launchOverride)),
      ),
    );
  }

  testWidgets('renders intro and launch button', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Photos are linked to a dive or a dive site as you import them.',
      ),
      findsOneWidget,
    );
    expect(find.text('Import media...'), findsOneWidget);
  });

  testWidgets(
    'a non-empty pick opens the review with one candidate per asset',
    (tester) async {
      await tester.pumpWidget(
        host(launchOverride: (context) async => [asset('a1'), asset('a2')]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Import media...'));
      await tester.pumpAndSettle();

      final page = tester.widget<MediaImportReviewPage>(
        find.byType(MediaImportReviewPage),
      );
      expect(page.candidates.map((c) => c.key), ['a1', 'a2']);
      expect(page.candidates.first.title, 'a1.jpg');
      expect(page.candidates.first.takenAt, DateTime.utc(2026, 6, 12, 10));
    },
  );

  test('the library import window has no effective lower bound', () {
    // A dive-less import must offer the whole gallery. The mobile picker
    // turns this bound into a hard photo_manager createTimeCond, so any
    // "recent enough" sentinel silently hides older assets -- scanned film
    // and slide libraries, which is exactly the media divers back-fill.
    expect(
      MediaImportView.libraryWindowStart.millisecondsSinceEpoch,
      lessThanOrEqualTo(0),
    );
  });

  testWidgets('an empty pick stays on the view', (tester) async {
    await tester.pumpWidget(host(launchOverride: (context) async => []));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import media...'));
    await tester.pumpAndSettle();
    expect(find.byType(MediaImportReviewPage), findsNothing);
  });
}
