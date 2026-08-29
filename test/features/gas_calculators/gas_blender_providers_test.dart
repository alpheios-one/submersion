import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart'
    show GasMix;
import 'package:submersion/features/gas_calculators/domain/blending/blender_preferences.dart';
import 'package:submersion/features/gas_calculators/domain/blending/equation_of_state.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';

import '../../support/fake_app_settings_repository.dart';

/// The blender seeds its cylinder volume and currency from the diver's
/// settings, and settingsProvider reaches for SharedPreferences. Overriding it
/// keeps this a pure provider test.
class _TestSettingsNotifier extends StateNotifier<AppSettings>
    implements SettingsNotifier {
  _TestSettingsNotifier(super.settings);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late ProviderContainer container;

  setUp(
    () => container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(
          (ref) => _TestSettingsNotifier(const AppSettings()),
        ),
      ],
    ),
  );
  tearDown(() => container.dispose());

  test('defaults reproduce the EAN32 fill procedure', () {
    final outcome = container.read(blenderResultProvider);
    expect(outcome.error, isNull);
    expect(outcome.result!.steps, hasLength(3));
    expect(outcome.result!.settledPressureBar, 200);
  });

  test('the fill temperature reaches the solver', () {
    container.read(blenderTargetMixProvider.notifier).state = const GasMix(
      o2: 18,
      he: 45,
    );
    container.read(blenderFillGas2Provider.notifier).state = const GasMix(
      o2: 0,
      he: 100,
    );
    final warm = container.read(blenderResultProvider).result!;

    container.read(blenderFillTempProvider.notifier).state = 5;
    final cold = container.read(blenderResultProvider).result!;

    expect(cold.steps.last.pressureBar, lessThan(warm.steps.last.pressureBar));
    expect(cold.settledPressureBar, 200);
  });

  test('the gas model reaches the solver', () {
    final z = container
        .read(blenderResultProvider)
        .result!
        .steps[1]
        .pressureBar;
    container.read(blenderGasModelProvider.notifier).state =
        BlendGasModel.ideal;
    final ideal = container
        .read(blenderResultProvider)
        .result!
        .steps[1]
        .pressureBar;
    expect(ideal, isNot(closeTo(z, 0.1)));
  });

  test('billing follows the current cylinder and prices', () {
    container.read(blenderCylinderLitersProvider.notifier).state = 12;
    // Prices are indexed by configured bank. The default EAN32 target skips
    // the helium bank, so its two steps draw on banks 0 and 2, and pricing
    // bank 1 does nothing for this blend.
    container.read(blenderGasPricesProvider.notifier).state = const [
      2.0,
      50.0,
      0.1,
    ];
    final billing = container.read(blenderBillingProvider);
    expect(billing.lines, hasLength(2));
    expect(billing.lines[0].gasIndex, 0);
    expect(billing.lines[1].gasIndex, 2);
    expect(billing.lines[1].unitPricePer100, 0.1);
    expect(billing.total, isNotNull);
  });

  test('templates start from the seeded list', () {
    expect(
      container.read(blenderTemplatesProvider),
      BlenderPreferences.seedTemplates,
    );
  });

  test('reset restores the defaults and bumps the epoch', () {
    container.read(blenderTargetPressureProvider.notifier).state = 300;
    container.read(blenderFillTempProvider.notifier).state = 5;
    final epoch = container.read(blenderResetEpochProvider);

    resetGasBlenderIn(container);

    expect(container.read(blenderTargetPressureProvider), 200);
    expect(container.read(blenderFillTempProvider), kReferenceTempC);
    expect(container.read(blenderResetEpochProvider), epoch + 1);
  });

  group('blenderPreferencesLoaderProvider', () {
    ProviderContainer containerWithRepo(FakeAppSettingsRepository repo) =>
        ProviderContainer(
          overrides: [
            settingsProvider.overrideWith(
              (ref) => _TestSettingsNotifier(const AppSettings()),
            ),
            appSettingsRepositoryProvider.overrideWithValue(repo),
          ],
        );

    test('a stored blob seeds the cylinder and mixes', () async {
      // Issue #1335: these fields joined the persisted blob so the blender
      // remembers the last fill across restarts, not just its templates and
      // billing defaults.
      final repo = FakeAppSettingsRepository()
        ..blenderPreferences =
            BlenderPreferences.defaults(cylinderWaterLiters: 12).copyWith(
              startPressureBar: 40,
              startMix: const GasMix(o2: 14.5, he: 57.2),
              targetPressureBar: 220,
              targetMix: const GasMix(o2: 15, he: 55),
              fillGas1: const GasMix(o2: 99.5),
              fillGas2: const GasMix(o2: 0, he: 99),
              fillGas3: const GasMix(o2: 20.9),
            );
      final loaderContainer = containerWithRepo(repo);
      addTearDown(loaderContainer.dispose);
      final epochBefore = loaderContainer.read(blenderResetEpochProvider);

      await loaderContainer.read(blenderPreferencesLoaderProvider.future);

      expect(loaderContainer.read(blenderStartPressureProvider), 40);
      expect(
        loaderContainer.read(blenderStartMixProvider),
        const GasMix(o2: 14.5, he: 57.2),
      );
      expect(loaderContainer.read(blenderTargetPressureProvider), 220);
      expect(
        loaderContainer.read(blenderTargetMixProvider),
        const GasMix(o2: 15, he: 55),
      );
      expect(
        loaderContainer.read(blenderFillGas1Provider),
        const GasMix(o2: 99.5),
      );
      expect(
        loaderContainer.read(blenderFillGas2Provider),
        const GasMix(o2: 0, he: 99),
      );
      expect(
        loaderContainer.read(blenderFillGas3Provider),
        const GasMix(o2: 20.9),
      );
      // Bumped so the text-editing controllers, which hold their own text
      // rather than reading a provider, re-seed from the freshly loaded
      // values instead of showing stale defaults.
      expect(loaderContainer.read(blenderResetEpochProvider), epochBefore + 1);
    });

    test('no stored blob leaves the hard-coded defaults in place', () async {
      final loaderContainer = containerWithRepo(FakeAppSettingsRepository());
      addTearDown(loaderContainer.dispose);

      await loaderContainer.read(blenderPreferencesLoaderProvider.future);

      expect(loaderContainer.read(blenderStartPressureProvider), 0.0);
      expect(
        loaderContainer.read(blenderStartMixProvider),
        const GasMix(o2: 21),
      );
      expect(loaderContainer.read(blenderTargetPressureProvider), 200.0);
    });
  });
}
