import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/features/dive_log/data/repositories/dive_repository_impl.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_repository_provider.dart';
import 'package:submersion/features/dive_log/presentation/widgets/site_suggestion_card.dart';
import 'package:submersion/features/dive_sites/data/services/site_matching_service.dart';
import 'package:submersion/features/dive_sites/domain/entities/dive_site.dart';
import 'package:submersion/features/dive_sites/presentation/providers/site_suggestion_providers.dart';

import '../../../media/presentation/support/media_widget_harness.dart';
import '../support/fake_matching_service.dart';

class _StubDiveRepository implements DiveRepository {
  final dismissed = <String>[];

  @override
  Future<void> setSiteSuggestionDismissed(String diveId, bool value) async {
    if (value) dismissed.add(diveId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late FakeMatchingService service;
  late _StubDiveRepository dives;
  var refreshed = 0;

  setUp(() {
    service = FakeMatchingService();
    dives = _StubDiveRepository();
    refreshed = 0;
  });

  Future<Widget> host(
    SiteSuggestion? suggestion, {
    DiveSite? currentSite,
    void Function(DiveSite?)? onSiteChanged,
  }) => mediaTestApp(
    overrides: [
      siteSuggestionForDiveProvider(
        'd1',
      ).overrideWith((ref) async => suggestion),
      diveRepositoryProvider.overrideWithValue(dives),
    ],
    home: Scaffold(
      body: SiteSuggestionCard(
        diveId: 'd1',
        currentSite: currentSite,
        onSiteChanged: onSiteChanged,
        refreshLists: () async => refreshed++,
      ),
    ),
  );

  testWidgets('renders nothing when there is no suggestion', (tester) async {
    await tester.pumpWidget(await host(null));
    await tester.pumpAndSettle();
    expect(find.byType(SiteSuggestionCard), findsOneWidget);
    expect(find.textContaining('Location'), findsNothing);
  });

  testWidgets('assign applies and reports the assigned site', (tester) async {
    final s = suggestionFor(
      service,
      recommended: 's1',
      candidates: const [
        MatchCandidateView(
          id: 's1',
          name: 'Blue Hole',
          isExisting: true,
          distanceMeters: 40,
          location: GeoPoint(0, 0),
        ),
      ],
    );
    DiveSite? reported;
    await tester.pumpWidget(
      await host(s, onSiteChanged: (site) => reported = site),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Assign Blue Hole'));
    await tester.pumpAndSettle();
    expect(service.applied.single.candidateId, 's1');
    expect(reported?.id, 's1');
    expect(refreshed, 1);
    expect(find.text('Assigned Blue Hole'), findsOneWidget);
  });

  testWidgets('dismiss writes the flag', (tester) async {
    await tester.pumpWidget(
      await host(suggestionFor(service, status: ProposalStatus.none)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(dives.dismissed, ['d1']);
  });

  testWidgets('create opens the quick dialog and links the new site', (
    tester,
  ) async {
    DiveSite? reported;
    await tester.pumpWidget(
      await host(
        suggestionFor(service, status: ProposalStatus.none),
        onSiteChanged: (site) => reported = site,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create Site'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Wall');
    await tester.tap(find.widgetWithText(FilledButton, 'Create Site').last);
    await tester.pumpAndSettle();
    expect(service.created.single.name, 'Wall');
    expect(reported?.id, 'created');
    expect(find.textContaining('Created site: Wall'), findsOneWidget);
  });
}
