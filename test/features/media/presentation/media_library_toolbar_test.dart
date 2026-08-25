import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/constants/sort_options.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_sites/presentation/providers/site_providers.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/domain/entities/media_library_filter.dart';
import 'package:submersion/features/media/presentation/providers/media_library_providers.dart';
import 'package:submersion/features/media/presentation/providers/media_library_sort_provider.dart';
import 'package:submersion/features/media/presentation/widgets/media_library_toolbar.dart';
import 'package:submersion/features/settings/data/repositories/app_settings_repository.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/features/trips/presentation/providers/trip_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

/// Both the view-mode notifier and the sort notifier read and WRITE app
/// settings. Without this override they reach the real repository, and the
/// awaited setMode/setSort calls below throw because no database is open
/// under flutter test.
class _FakeSettingsRepo extends AppSettingsRepository {
  final Map<String, String> values = {};

  @override
  Future<String?> getRawSetting(String key) async => values[key];

  @override
  Future<void> setRawSetting(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(
      overrides: [
        sitesProvider.overrideWith((ref) async => []),
        allTripsProvider.overrideWith((ref) async => []),
        appSettingsRepositoryProvider.overrideWithValue(_FakeSettingsRepo()),
      ],
    );
    addTearDown(container.dispose);
  });

  Widget host() => UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      locale: Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: MediaLibraryToolbar()),
    ),
  );

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
  }

  testWidgets('the filter badge is hidden until something is filtered', (
    tester,
  ) async {
    await pump(tester);

    expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isFalse);

    container.read(mediaLibraryFilterProvider.notifier).state =
        const MediaLibraryFilter(mediaType: MediaType.photo);
    await tester.pumpAndSettle();

    expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isTrue);
  });

  testWidgets('the sort button opens the sheet and writes the choice', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();

    expect(find.text('Sort media'), findsOneWidget);
    await tester.tap(find.text('File Name'));
    await tester.pumpAndSettle();

    expect(
      container.read(mediaLibrarySortProvider).field,
      MediaSortField.fileName,
    );
  });

  testWidgets('the sort button is absent outside grid mode', (tester) async {
    await pump(tester);
    expect(find.byIcon(Icons.sort), findsOneWidget);

    await container
        .read(mediaLibraryViewModeProvider.notifier)
        .setMode(MediaLibraryViewMode.timeline);
    await tester.pumpAndSettle();

    // The grouped modes consume an already-date-sorted stream, so offering a
    // name or size sort there would shred the timeline into one-item groups.
    expect(find.byIcon(Icons.sort), findsNothing);
  });

  testWidgets('the filter button opens the filter sheet', (tester) async {
    await pump(tester);

    await tester.tap(find.byIcon(Icons.filter_list));
    await tester.pumpAndSettle();

    expect(find.text('Filter media'), findsOneWidget);
  });
}
