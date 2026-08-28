import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/gas_calculators/domain/blending/cylinder_template.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_billing_card.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

class _TestSettingsNotifier extends StateNotifier<AppSettings>
    implements SettingsNotifier {
  _TestSettingsNotifier(super.settings);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<WidgetRef> _pump(WidgetTester tester) async {
  late WidgetRef captured;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(
          (ref) =>
              _TestSettingsNotifier(const AppSettings(defaultCurrency: 'CHF')),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: Consumer(
              builder: (context, ref, _) {
                captured = ref;
                return const BlenderBillingCard();
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
  // The arithmetic itself is pinned to the cent against both worked examples
  // in blend_billing_test.dart. What matters here is that the card is wired to
  // the real cylinder volume and prices, which proportionality demonstrates
  // without restating the formula.
  testWidgets('the total scales with the cylinder volume', (tester) async {
    final ref = await _pump(tester);
    ref.read(blenderGasPricesProvider.notifier).state = const [2.0, 7.99, 0.1];
    ref.read(blenderCylinderLitersProvider.notifier).state = 3;
    await tester.pumpAndSettle();
    final small = ref.read(blenderBillingProvider).total!;

    ref.read(blenderCylinderLitersProvider.notifier).state = 6;
    await tester.pumpAndSettle();
    final large = ref.read(blenderBillingProvider).total!;

    expect(large, closeTo(small * 2, 1e-9));
    expect(find.text('Total'), findsOneWidget);
  });

  testWidgets('shows the bar delivered on every line', (tester) async {
    final ref = await _pump(tester);
    ref.read(blenderCylinderLitersProvider.notifier).state = 12;
    await tester.pumpAndSettle();
    expect(find.textContaining('+'), findsWidgets);
  });

  testWidgets('an unpriced gas suppresses the total', (tester) async {
    final ref = await _pump(tester);
    ref.read(blenderGasPricesProvider.notifier).state = const [2.0, null, null];
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter a price for every gas'), findsOneWidget);
  });

  testWidgets('states the billing basis', (tester) async {
    await _pump(tester);
    expect(find.textContaining('pressure delivered'), findsOneWidget);
  });

  testWidgets('defaults the currency to the diver setting', (tester) async {
    final ref = await _pump(tester);
    expect(ref.read(blenderCurrencyProvider), 'CHF');
  });

  testWidgets('a cylinder preset fills the volume field', (tester) async {
    // The seeded sizes are the blending-bench ones named in issue #1100: the
    // 2 and 3 litre decant bottles, an AL80, and a steel twinset (issue #1335
    // follow-up: seeded into the editable list, not a separate static one).
    final ref = await _pump(tester);
    await tester.tap(find.byKey(const Key('blender-cylinder-presets')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('3 L (3 L)'));
    await tester.pumpAndSettle();

    expect(ref.read(blenderCylinderLitersProvider), closeTo(3, 0.01));
  });

  testWidgets('the preset list offers only the diver-managed sizes', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.byKey(const Key('blender-cylinder-presets')));
    await tester.pumpAndSettle();
    for (final label in [
      '2 L (2 L)',
      '3 L (3 L)',
      'AL80 (11.1 L)',
      'Steel 12 L twinset (24 L)',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('the dropdown reflects an edited template list exactly', (
    tester,
  ) async {
    // Issue #1335 follow-up: no separate static preset list any more, so a
    // provider override fully replaces what the dropdown offers.
    final ref = await _pump(tester);
    ref.read(blenderCylinderTemplatesProvider.notifier).state = const [
      CylinderTemplate(name: 'Deco bottle', liters: 5),
    ];
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('blender-cylinder-presets')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Deco bottle'), findsOneWidget);
    expect(find.text('2 L (2 L)'), findsNothing);

    await tester.tap(find.textContaining('Deco bottle'));
    await tester.pumpAndSettle();
    expect(ref.read(blenderCylinderLitersProvider), closeTo(5, 0.01));
  });

  testWidgets('a second gear opens settings scrolled to billing defaults', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.byKey(const Key('blender-billing-settings')));
    await tester.pumpAndSettle();

    expect(find.text('Default settings and billing'), findsOneWidget);
    expect(find.text('Cylinder sizes'), findsOneWidget);
  });
}
