import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_defaults_card.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../support/fake_app_settings_repository.dart';

class _TestSettingsNotifier extends StateNotifier<AppSettings>
    implements SettingsNotifier {
  _TestSettingsNotifier(super.settings);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// The Riverpod `Override` type is sealed and not re-exported, so overrides
// are threaded through as `dynamic` and cast at the `ProviderScope` boundary
// (see test/helpers/test_app.dart).
Future<WidgetRef> _pump(
  WidgetTester tester, {
  List<dynamic> overrides = const [],
}) async {
  late WidgetRef captured;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(
          (ref) =>
              _TestSettingsNotifier(const AppSettings(defaultCurrency: 'CHF')),
        ),
        ...overrides,
      ].cast(),
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: Consumer(
              builder: (context, ref, _) {
                captured = ref;
                return const BlenderDefaultsCard();
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return captured;
}

void main() {
  testWidgets('a stored price seeds the field, converted for display', (
    tester,
  ) async {
    // A blank box (the default) skips the conversion entirely (issue #1215's
    // original bug); a stored price has to go through it on the very first
    // frame, before any diver edit.
    await _pump(
      tester,
      overrides: [
        blenderGasPricesProvider.overrideWith(
          (ref) => const [12.5, null, null],
        ),
      ],
    );

    expect(find.widgetWithText(TextField, '12.5'), findsOneWidget);
  });

  testWidgets('choosing a currency writes and persists it', (tester) async {
    final repo = FakeAppSettingsRepository();
    final ref = await _pump(
      tester,
      overrides: [appSettingsRepositoryProvider.overrideWithValue(repo)],
    );

    await tester.tap(find.byKey(const Key('blender-currency')));
    await tester.pumpAndSettle();
    // The open menu only builds items near the selected one (CHF), and even a
    // built neighbour can render outside the popup's visible viewport, so it
    // has to be scrolled into view before the tap will actually hit it.
    final gbpItem = find.text('GBP  £').last;
    await tester.ensureVisible(gbpItem);
    await tester.pumpAndSettle();
    await tester.tap(gbpItem);
    await tester.pumpAndSettle();

    expect(ref.read(blenderCurrencyProvider), 'GBP');
    expect(repo.blenderPreferences?.currencyCode, 'GBP');
  });

  testWidgets('submitting a price field saves the preferences', (tester) async {
    final repo = FakeAppSettingsRepository();
    await _pump(
      tester,
      overrides: [appSettingsRepositoryProvider.overrideWithValue(repo)],
    );

    await tester.enterText(find.byType(TextField).first, '9.5');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(repo.blenderPreferences?.gasPrices[0], closeTo(9.5, 0.001));
  });
}
