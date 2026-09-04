import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/gas_calculators/presentation/pages/blender_settings_page.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_fill_gases_card.dart';
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
          (ref) => _TestSettingsNotifier(const AppSettings()),
        ),
        ...overrides,
      ].cast(),
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Consumer(
          builder: (context, ref, _) {
            captured = ref;
            return const BlenderSettingsPage();
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return captured;
}

void main() {
  testWidgets('submitting a fill-gas row saves the preferences', (
    tester,
  ) async {
    // Issue #1335: fill gases now persist across restarts too, the same as
    // the cylinder and target fill.
    final repo = FakeAppSettingsRepository();
    final ref = await _pump(
      tester,
      overrides: [appSettingsRepositoryProvider.overrideWithValue(repo)],
    );

    // The first fill-gas row's O2 field: no pressure column on this card, so
    // O2 is the very first field.
    await tester.enterText(find.byType(TextField).first, '95');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(ref.read(blenderFillGas1Provider).o2, closeTo(95, 0.001));
    expect(repo.blenderPreferences?.fillGas1.o2, closeTo(95, 0.001));
  });

  testWidgets(
    'fill-gas rows are labelled by the computed gas name, not a number',
    (tester) async {
      // PR #1359 review point 1: "1./2./3." told a diver nothing about what
      // each bank actually holds. The defaults are O2, helium, then air.
      await _pump(tester);

      expect(find.text('O₂'), findsOneWidget);
      expect(find.text('Helium'), findsOneWidget);
      expect(find.text('Air'), findsOneWidget);
      expect(find.text('1.'), findsNothing);
    },
  );

  testWidgets("the O2/He fields line up regardless of each row's label width", (
    tester,
  ) async {
    // App-test feedback after PR #1359: "Helium" (row 2's default label) is
    // wider than "O₂" or "Air", and an unconstrained label pushed that
    // row's fields out of line with the other two.
    await _pump(tester);

    final o2Fields = find.descendant(
      of: find.byType(BlenderFillGasesCard),
      matching: find.byWidgetPredicate(
        (w) =>
            w is TextField && (w.decoration?.labelText ?? '').startsWith('O'),
      ),
    );
    expect(o2Fields, findsNWidgets(3));
    final lefts = [
      for (var i = 0; i < 3; i++) tester.getTopLeft(o2Fields.at(i)).dx,
    ];

    expect(lefts.toSet(), hasLength(1));
  });

  testWidgets('a fill-gas label updates as its O2/He fields change', (
    tester,
  ) async {
    await _pump(tester);

    await tester.enterText(find.byType(TextField).first, '32');
    await tester.pumpAndSettle();

    expect(find.text('EAN32'), findsOneWidget);
    expect(find.text('O₂'), findsNothing);
  });

  testWidgets('an invalid fill-gas mix is flagged inline on the row', (
    tester,
  ) async {
    // PR #1359 review point 2: computeBlend throws the same
    // BlendError.invalidMix, but until now that only surfaced back on the
    // calculator page -- a navigation away from the field that caused it.
    await _pump(tester);

    final heFields = find.byWidgetPredicate(
      (w) => w is TextField && (w.decoration?.labelText ?? '').startsWith('He'),
    );
    await tester.enterText(heFields.first, '150');
    await tester.pumpAndSettle();

    expect(find.text("A gas mix's O₂ + He cannot exceed 100%."), findsWidgets);
  });

  testWidgets('a stored price seeds its row field, converted for display', (
    tester,
  ) async {
    // Eric's PR #1359 review point 3: the price used to live on
    // BlenderDefaultsCard; it now sits directly below its own fill-gas row.
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

  testWidgets('submitting a fill-gas row price field saves the preferences', (
    tester,
  ) async {
    final repo = FakeAppSettingsRepository();
    await _pump(
      tester,
      overrides: [appSettingsRepositoryProvider.overrideWithValue(repo)],
    );

    // Row order is O2, He, then price, so the first row's price field is the
    // third TextField on the card.
    final priceField = find.byWidgetPredicate(
      (w) =>
          w is TextField && (w.decoration?.labelText ?? '').contains('Price'),
    );
    await tester.enterText(priceField.first, '9.5');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(repo.blenderPreferences?.gasPrices[0], closeTo(9.5, 0.001));
  });
}
