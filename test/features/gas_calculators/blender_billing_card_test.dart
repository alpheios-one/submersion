import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_billing_card.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/features/tank_presets/domain/entities/tank_preset_entity.dart';
import 'package:submersion/features/tank_presets/presentation/providers/tank_preset_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../helpers/test_app.dart';
import '../../support/fake_app_settings_repository.dart';

class _TestSettingsNotifier extends StateNotifier<AppSettings>
    implements SettingsNotifier {
  _TestSettingsNotifier(super.settings);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Stands in for the diver's real tank presets (issue #1335 follow-up: the
/// cylinder dropdown reads the global preset list now, not a blender-only
/// vault). Working pressure and material are set but never read by the
/// blender, which only wants a label and a water volume.
List<TankPresetEntity> _presets() => [
  TankPresetEntity.create(
    id: 'preset-al80',
    name: 'al80',
    displayName: 'AL80',
    volumeLiters: 11.1,
    workingPressureBar: 207,
    material: TankMaterial.aluminum,
  ),
  TankPresetEntity.create(
    id: 'preset-deco',
    name: 'deco3',
    displayName: 'Deco bottle',
    volumeLiters: 3,
    workingPressureBar: 200,
    material: TankMaterial.aluminum,
  ),
];

// The Riverpod `Override` type is sealed and not re-exported, so overrides
// are threaded through as `dynamic` and cast at the `ProviderScope` boundary
// (see test/helpers/test_app.dart).
Future<WidgetRef> _pump(
  WidgetTester tester, {
  List<dynamic> overrides = const [],
  List<TankPresetEntity>? presets,
}) async {
  late WidgetRef captured;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(
          (ref) =>
              _TestSettingsNotifier(const AppSettings(defaultCurrency: 'CHF')),
        ),
        tankPresetsProvider.overrideWith((ref) async => presets ?? _presets()),
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
    final ref = await _pump(tester);
    await tester.tap(find.byKey(const Key('blender-cylinder-presets')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deco bottle (3 L)'));
    await tester.pumpAndSettle();

    expect(ref.read(blenderCylinderLitersProvider), closeTo(3, 0.01));
  });

  testWidgets('the preset list offers exactly the diver-managed sizes', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.byKey(const Key('blender-cylinder-presets')));
    await tester.pumpAndSettle();
    for (final label in ['AL80 (11.1 L)', 'Deco bottle (3 L)']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets("the dropdown reflects the diver's tank presets exactly", (
    tester,
  ) async {
    // Issue #1335 follow-up: the blender's own cylinder-size vault is gone,
    // so a different set of tank presets fully replaces what the dropdown
    // offers.
    final ref = await _pump(
      tester,
      presets: [
        TankPresetEntity.create(
          id: 'preset-twinset',
          name: 'twinset',
          displayName: 'Twinset',
          volumeLiters: 24,
          workingPressureBar: 200,
          material: TankMaterial.steel,
        ),
      ],
    );

    await tester.tap(find.byKey(const Key('blender-cylinder-presets')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Twinset'), findsOneWidget);
    expect(find.text('AL80 (11.1 L)'), findsNothing);

    await tester.tap(find.textContaining('Twinset'));
    await tester.pumpAndSettle();
    expect(ref.read(blenderCylinderLitersProvider), closeTo(24, 0.01));
  });

  testWidgets('the cylinder-sizes link navigates to the global tank presets', (
    tester,
  ) async {
    late String location;
    final router = GoRouter(
      initialLocation: '/gas-calculators',
      routes: [
        GoRoute(
          path: '/gas-calculators',
          builder: (context, state) => const Scaffold(
            body: SingleChildScrollView(child: BlenderBillingCard()),
          ),
        ),
        GoRoute(
          path: '/tank-presets',
          builder: (context, state) {
            location = GoRouterState.of(context).uri.toString();
            return const Scaffold(body: Text('Tank Presets'));
          },
        ),
      ],
    );

    await tester.pumpWidget(
      testAppRouter(
        locale: const Locale('en'),
        router: router,
        overrides: [
          settingsProvider.overrideWith(
            (ref) => _TestSettingsNotifier(
              const AppSettings(defaultCurrency: 'CHF'),
            ),
          ),
          tankPresetsProvider.overrideWith((ref) async => _presets()),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('blender-cylinder-sizes-link')));
    await tester.pumpAndSettle();

    expect(location, '/tank-presets');
  });

  testWidgets('submitting a typed cylinder volume saves the preferences', (
    tester,
  ) async {
    final repo = FakeAppSettingsRepository();
    final ref = await _pump(
      tester,
      overrides: [appSettingsRepositoryProvider.overrideWithValue(repo)],
    );

    await tester.enterText(find.byType(TextField).first, '15');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(ref.read(blenderCylinderLitersProvider), closeTo(15, 0.001));
    expect(repo.blenderPreferences?.cylinderWaterLiters, closeTo(15, 0.001));
  });
}
