import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/media/data/parsers/manifest_entry.dart';
import 'package:submersion/features/media/data/parsers/manifest_format.dart';
import 'package:submersion/features/media/data/parsers/manifest_parse_result.dart';
import 'package:submersion/features/media/data/services/manifest_fetch_service.dart';
import 'package:submersion/features/media/data/services/network_fetch_pipeline.dart';
import 'package:submersion/features/media/presentation/pages/media_import_review_page.dart';
import 'package:submersion/features/media/presentation/providers/manifest_tab_providers.dart';
import 'package:submersion/features/media/presentation/providers/media_resolver_providers.dart';
import 'package:submersion/features/media/presentation/providers/url_tab_providers.dart';
import 'package:submersion/features/media/presentation/widgets/manifest_mode_panel.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

class _SeededManifestTabNotifier extends ManifestTabNotifier {
  _SeededManifestTabNotifier(
    ManifestTabState seed, {
    required super.fetchService,
  }) {
    state = seed;
  }
}

class _StubFetcher implements ManifestFetchService {
  const _StubFetcher();

  @override
  Future<ManifestFetchOutcome> fetch(
    Uri url, {
    ManifestFormat? formatOverride,
    String? ifNoneMatch,
    String? ifModifiedSince,
  }) async => const ManifestFetchSuccess(
    parsed: ManifestParseResult(format: ManifestFormat.json, entries: []),
  );

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Resolves every entry as-is and records what gets inserted.
class _FakePipeline implements NetworkFetchPipeline {
  final List<List<NetworkInsertRequest>> inserted = [];

  @override
  Future<List<ResolvedNetworkMedia>> resolveManifestEntries(
    List<ManifestEntry> entries,
  ) async => [
    for (final e in entries)
      ResolvedNetworkMedia(uri: Uri.parse(e.url), entry: e),
  ];

  @override
  Future<List<String>> insertResolved(
    List<NetworkInsertRequest> requests, {
    String? subscriptionId,
  }) async {
    inserted.add(requests);
    return [for (var i = 0; i < requests.length; i++) 'm$i'];
  }

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  // No takenAt: the review shows "No matching dive" and never touches a
  // dive repository, which keeps this test free of that provider.
  const entry = ManifestEntry(
    entryKey: 'k1',
    url: 'https://feed.example.com/a.jpg',
  );

  Widget host(_FakePipeline pipeline) {
    const stub = _StubFetcher();
    return ProviderScope(
      overrides: [
        manifestFetchServiceProvider.overrideWithValue(stub),
        networkFetchPipelineProvider.overrideWithValue(pipeline),
        manifestTabProvider.overrideWith(
          (ref) => _SeededManifestTabNotifier(
            const ManifestTabShowingPreview(
              url: 'https://feed.example.com/m.json',
              result: ManifestParseResult(
                format: ManifestFormat.json,
                entries: [entry],
              ),
            ),
            fetchService: stub,
          ),
        ),
      ],
      child: const MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ManifestModePanel()),
      ),
    );
  }

  testWidgets('Import opens the review and inserts nothing until confirmed', (
    tester,
  ) async {
    final pipeline = _FakePipeline();
    await tester.pumpWidget(host(pipeline));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Import 1 entry'));
    await tester.pumpAndSettle();

    expect(find.byType(MediaImportReviewPage), findsOneWidget);
    expect(find.text('No matching dive'), findsOneWidget);
    expect(pipeline.inserted, isEmpty);
  });
}
