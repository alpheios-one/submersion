import 'package:flutter/material.dart' show DateTimeRange;
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/services/logger_service.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart'
    show GasMix;
import 'package:submersion/features/gas_calculators/domain/blending/billed_fill.dart';
import 'package:submersion/features/gas_calculators/domain/blending/blend_billing.dart';
import 'package:submersion/features/gas_calculators/domain/blending/blender_preferences.dart';
import 'package:submersion/features/gas_calculators/domain/gas_blender.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';

/// Starting cylinder pressure (bar), read at the fill temperature. Zero means
/// an empty cylinder.
final blenderStartPressureProvider = StateProvider<double>((ref) => 0.0);

/// Mix already in the cylinder.
final blenderStartMixProvider = StateProvider<GasMix>(
  (ref) => const GasMix(o2: 21),
);

/// Desired final pressure (bar), once settled at the settled temperature.
final blenderTargetPressureProvider = StateProvider<double>((ref) => 200.0);

/// Desired final mix.
final blenderTargetMixProvider = StateProvider<GasMix>(
  (ref) => const GasMix(o2: 32),
);

/// Fill gases, applied in this order. The default O2 -> helium -> air is the
/// order a fill station works in: helium is decanted while the cylinder is
/// still low, and the compressor tops off with air last. A helium-free target
/// skips the helium source and blends O2 with air.
final blenderFillGas1Provider = StateProvider<GasMix>(
  (ref) => const GasMix(o2: 100),
);
final blenderFillGas2Provider = StateProvider<GasMix>(
  (ref) => const GasMix(o2: 0, he: 100),
);
final blenderFillGas3Provider = StateProvider<GasMix>(
  (ref) => const GasMix(o2: 21),
);

/// Cylinder temperature while filling, in Celsius.
final blenderFillTempProvider = StateProvider<double>((ref) => kReferenceTempC);

/// Temperature the cylinder settles to afterwards, in Celsius.
final blenderSettledTempProvider = StateProvider<double>(
  (ref) => kReferenceTempC,
);

/// Which equation of state the blend is solved with.
final blenderGasModelProvider = StateProvider<BlendGasModel>(
  (ref) => BlendGasModel.zFactor,
);

/// Price per 100 litres of free gas, positional against the three fill gases.
final blenderGasPricesProvider = StateProvider<List<double?>>(
  (ref) => const [null, null, null],
);

/// Currency the prices are in, defaulting to the diver's own.
final blenderCurrencyProvider = StateProvider<String>(
  (ref) => ref.read(settingsProvider).defaultCurrency,
);

/// Cylinder water capacity in litres, for costing only. Partial-pressure
/// mixing is driven by pressure and needs no cylinder.
final blenderCylinderLitersProvider = StateProvider<double>(
  (ref) => ref.read(settingsProvider).defaultTankVolume,
);

/// Saved target mixes.
final blenderTemplatesProvider = StateProvider<List<MixTemplate>>(
  (ref) => BlenderPreferences.seedTemplates,
);

/// Cylinders already finished and put on the bill, oldest first.
final blenderBilledFillsProvider = StateProvider<List<BilledFill>>(
  (ref) => const [],
);

/// Who the bill is for. Free text; the costing card seeds it from the
/// logbook's diver.
final blenderBilledToProvider = StateProvider<String>((ref) => '');

/// When the running bill started. Defaults to today so the date is editable
/// from the moment a bill is open, not only once it is paid.
final blenderBilledDateProvider = StateProvider<DateTime>(
  (ref) => DateTime.now(),
);

/// Bills already paid and archived, oldest first.
final blenderArchivedInvoicesProvider = StateProvider<List<ArchivedInvoice>>(
  (ref) => const [],
);

/// The date range narrowing the invoice archive view. Ephemeral by design,
/// matching [preDiveSessionFilterProvider]: a filter is a view of the current
/// screen, not a stored preference, so it resets the next time the archive
/// is opened rather than persisting across sessions.
final blenderInvoiceArchiveFilterProvider = StateProvider<DateTimeRange?>(
  (ref) => null,
);

/// Archived invoices matching [blenderInvoiceArchiveFilterProvider], newest
/// first so a fill station checking "what did I just charge" does not have to
/// scroll past months of history.
final filteredBlenderArchivedInvoicesProvider = Provider<List<ArchivedInvoice>>(
  (ref) {
    final invoices = ref.watch(blenderArchivedInvoicesProvider);
    final range = ref.watch(blenderInvoiceArchiveFilterProvider);
    final filtered = range == null
        ? invoices
        : invoices
              .where((invoice) => _inDateRange(invoice.date, range))
              .toList();
    return filtered.reversed.toList();
  },
);

/// Whether [date] falls within [range], inclusive of the whole end day: the
/// picker yields whole days, so an invoice paid at 23:30 on the last selected
/// day must still match.
bool _inDateRange(DateTime date, DateTimeRange range) {
  final startOfFirstDay = DateTime(
    range.start.year,
    range.start.month,
    range.start.day,
  );
  final endOfLastDay = DateTime(
    range.end.year,
    range.end.month,
    range.end.day,
  ).add(const Duration(days: 1));
  return !date.isBefore(startOfFirstDay) && date.isBefore(endOfLastDay);
}

/// Bumped by a reset so the input fields re-seed their controllers.
final blenderResetEpochProvider = StateProvider<int>((ref) => 0);

/// Either a computed fill procedure or the reason one is not achievable.
class BlenderOutcome {
  const BlenderOutcome({this.result, this.error, this.drainToBar});
  final BlendResult? result;
  final BlendError? error;

  /// Set when the blend fails only because the cylinder holds too much gas:
  /// the pressure to drain down to before starting.
  final double? drainToBar;
}

/// The fill procedure for the current inputs; carries a [BlendError] instead of
/// throwing when the requested blend is impossible.
final blenderResultProvider = Provider<BlenderOutcome>((ref) {
  try {
    return BlenderOutcome(
      result: computeBlend(
        GasBlenderInputs(
          startPressureBar: ref.watch(blenderStartPressureProvider),
          start: ref.watch(blenderStartMixProvider),
          targetPressureBar: ref.watch(blenderTargetPressureProvider),
          target: ref.watch(blenderTargetMixProvider),
          fillGas1: ref.watch(blenderFillGas1Provider),
          fillGas2: ref.watch(blenderFillGas2Provider),
          fillGas3: ref.watch(blenderFillGas3Provider),
          model: ref.watch(blenderGasModelProvider),
          fillTempC: ref.watch(blenderFillTempProvider),
          settledTempC: ref.watch(blenderSettledTempProvider),
        ),
      ),
    );
  } on BlendException catch (e) {
    return BlenderOutcome(error: e.error, drainToBar: e.drainToBar);
  }
});

/// What the current blend costs. Empty when there is no blend to price.
final blenderBillingProvider = Provider<BillingResult>((ref) {
  final blend = ref.watch(blenderResultProvider).result;
  if (blend == null) {
    return const BillingResult(lines: [], total: null);
  }
  return computeBlendCost(
    blend: blend,
    waterLiters: ref.watch(blenderCylinderLitersProvider),
    pricesPer100: ref.watch(blenderGasPricesProvider),
  );
});

// no-tick: a one-shot SEED with side effects, not a cached query. Re-running
// it rewrites seven StateProviders and bumps the reset epoch, so a tick from
// the blender's own save would re-seed every text field while the diver was
// still typing in it. The trade is deliberate and bounded: preferences changed
// on another device arrive on the next open of the calculator rather than
// mid-session, and nothing here renders a stale query result.
/// Loads the saved preferences once and pushes them into the state providers.
///
/// A first run has no stored blob, which is exactly what seeds the default
/// templates. Deleting every template afterwards stores an empty list, and an
/// empty list is not an absent blob, so the deletion sticks.
final blenderPreferencesLoaderProvider = FutureProvider<void>((ref) async {
  final stored = await ref
      .read(appSettingsRepositoryProvider)
      .getBlenderPreferences();
  if (stored == null) return;
  ref.read(blenderTemplatesProvider.notifier).state = stored.templates;
  ref.read(blenderGasPricesProvider.notifier).state = stored.gasPrices;
  ref.read(blenderFillTempProvider.notifier).state = stored.fillTempC;
  ref.read(blenderSettledTempProvider.notifier).state = stored.settledTempC;
  ref.read(blenderCylinderLitersProvider.notifier).state =
      stored.cylinderWaterLiters;
  ref.read(blenderGasModelProvider.notifier).state = stored.model;
  ref.read(blenderBilledFillsProvider.notifier).state = stored.billedFills;
  ref.read(blenderBilledToProvider.notifier).state = stored.billedTo;
  if (stored.billedDate != null) {
    ref.read(blenderBilledDateProvider.notifier).state = stored.billedDate!;
  }
  ref.read(blenderArchivedInvoicesProvider.notifier).state =
      stored.archivedInvoices;
  if (stored.currencyCode != null) {
    ref.read(blenderCurrencyProvider.notifier).state = stored.currencyCode!;
  }
  // The input fields hold their own text, seeded once in initState. Without
  // this the cylinder volume and price boxes keep showing defaults over
  // freshly loaded preferences, and the next edit saves those defaults back
  // over what was stored (PR #1215 review).
  ref.read(blenderResetEpochProvider.notifier).state++;
});

const _log = LoggerService('GasBlenderPreferences');

/// Persist everything the blender remembers. Called after a settled edit, not
/// per keystroke, so typing a price is one database write rather than one per
/// character.
///
/// A failed write is logged rather than propagated. The repository rethrows so
/// the failure is never invisible, but a blender preference is not worth
/// interrupting a fill procedure over, and the value the diver just chose is
/// already live in the provider either way.
Future<void> saveBlenderPreferences(WidgetRef ref) async {
  try {
    await ref
        .read(appSettingsRepositoryProvider)
        .setBlenderPreferences(
          BlenderPreferences(
            templates: ref.read(blenderTemplatesProvider),
            gasPrices: ref.read(blenderGasPricesProvider),
            currencyCode: ref.read(blenderCurrencyProvider),
            fillTempC: ref.read(blenderFillTempProvider),
            settledTempC: ref.read(blenderSettledTempProvider),
            cylinderWaterLiters: ref.read(blenderCylinderLitersProvider),
            model: ref.read(blenderGasModelProvider),
            billedFills: ref.read(blenderBilledFillsProvider),
            billedTo: ref.read(blenderBilledToProvider),
            billedDate: ref.read(blenderBilledDateProvider),
            archivedInvoices: ref.read(blenderArchivedInvoicesProvider),
          ),
        );
  } catch (e, stackTrace) {
    _log.error(
      'Failed to save blender preferences',
      error: e,
      stackTrace: stackTrace,
    );
  }
}

/// Reset the gas blender inputs to defaults and re-seed its input fields.
///
/// Deliberately duplicated against [resetGasBlenderIn] rather than routed
/// through a shared generic callback: `WidgetRef` and `ProviderContainer` are
/// unrelated types that merely happen to share a `read` shape, and the generic
/// signature that unifies them is harder to read than twelve assignments.
void resetGasBlender(WidgetRef ref) {
  ref.read(blenderStartPressureProvider.notifier).state = 0.0;
  ref.read(blenderStartMixProvider.notifier).state = const GasMix(o2: 21);
  ref.read(blenderTargetPressureProvider.notifier).state = 200.0;
  ref.read(blenderTargetMixProvider.notifier).state = const GasMix(o2: 32);
  ref.read(blenderFillGas1Provider.notifier).state = const GasMix(o2: 100);
  ref.read(blenderFillGas2Provider.notifier).state = const GasMix(
    o2: 0,
    he: 100,
  );
  ref.read(blenderFillGas3Provider.notifier).state = const GasMix(o2: 21);
  ref.read(blenderFillTempProvider.notifier).state = kReferenceTempC;
  ref.read(blenderSettledTempProvider.notifier).state = kReferenceTempC;
  ref.read(blenderGasModelProvider.notifier).state = BlendGasModel.zFactor;
  ref.read(blenderResetEpochProvider.notifier).state++;
}

/// Test-facing form of [resetGasBlender].
void resetGasBlenderIn(ProviderContainer container) {
  container.read(blenderStartPressureProvider.notifier).state = 0.0;
  container.read(blenderStartMixProvider.notifier).state = const GasMix(o2: 21);
  container.read(blenderTargetPressureProvider.notifier).state = 200.0;
  container.read(blenderTargetMixProvider.notifier).state = const GasMix(
    o2: 32,
  );
  container.read(blenderFillGas1Provider.notifier).state = const GasMix(
    o2: 100,
  );
  container.read(blenderFillGas2Provider.notifier).state = const GasMix(
    o2: 0,
    he: 100,
  );
  container.read(blenderFillGas3Provider.notifier).state = const GasMix(o2: 21);
  container.read(blenderFillTempProvider.notifier).state = kReferenceTempC;
  container.read(blenderSettledTempProvider.notifier).state = kReferenceTempC;
  container.read(blenderGasModelProvider.notifier).state =
      BlendGasModel.zFactor;
  container.read(blenderResetEpochProvider.notifier).state++;
}
