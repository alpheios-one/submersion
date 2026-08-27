import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_sites/presentation/providers/site_match_review_notifier.dart';
import 'package:submersion/features/media/presentation/helpers/offer_site_review_after_import.dart';

import '../../../../helpers/test_app.dart';

void main() {
  Future<List<Object?>> pump(
    WidgetTester tester,
    List<String> eligible, {
    required List<String> imported,
    List<String>? overrideKey,
  }) async {
    final pushed = <Object?>[];
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () =>
                    offerSiteReviewAfterImport(context, ref, imported),
                child: const Text('done'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/dives/match-sites',
          builder: (context, state) {
            pushed.add(state.extra);
            return const Scaffold(body: Text('review page'));
          },
        ),
      ],
    );
    await tester.pumpWidget(
      testAppRouter(
        router: router,
        overrides: [
          eligibleImportedDivesProvider(
            ImportedDiveIds(overrideKey ?? imported),
          ).overrideWith((ref) async => eligible),
        ],
      ),
    );
    return pushed;
  }

  testWidgets('offers a review with the eligible count and navigates', (
    tester,
  ) async {
    final pushed = await pump(
      tester,
      ['d1', 'd2'],
      imported: ['d1', 'd2', 'd3'],
    );
    await tester.tap(find.text('done'));
    await tester.pumpAndSettle();
    expect(
      find.text('2 dives could get a site from their photos'),
      findsOneWidget,
    );
    await tester.tap(find.text('Review sites'));
    await tester.pumpAndSettle();
    expect(find.text('review page'), findsOneWidget);
    expect(pushed.single, ['d1', 'd2']);
  });

  testWidgets('stays silent when nothing is eligible or nothing was imported', (
    tester,
  ) async {
    await pump(tester, const [], imported: ['d1']);
    await tester.tap(find.text('done'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('the provider key is canonical regardless of import order', (
    tester,
  ) async {
    // ImportedDiveIds is an Equatable over the list, so an unsorted key would
    // miss this override entirely and address a second family entry.
    final pushed = await pump(
      tester,
      ['d1', 'd2'],
      imported: ['d2', 'd1', 'd2'],
      overrideKey: ['d1', 'd2'],
    );
    await tester.tap(find.text('done'));
    await tester.pumpAndSettle();
    expect(
      find.text('2 dives could get a site from their photos'),
      findsOneWidget,
    );
    await tester.tap(find.text('Review sites'));
    await tester.pumpAndSettle();
    expect(pushed.single, ['d1', 'd2']);
  });
}
