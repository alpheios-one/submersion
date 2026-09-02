import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/utils/currency.dart';
import 'package:submersion/core/utils/number_input.dart';
import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/divers/presentation/providers/diver_providers.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart'
    show GasMix;
import 'package:submersion/features/gas_calculators/domain/blending/billed_fill.dart';
import 'package:submersion/features/gas_calculators/domain/blending/blender_preferences.dart';
import 'package:submersion/features/gas_calculators/domain/blending/flush_fee.dart';
import 'package:submersion/features/gas_calculators/domain/tank_spec.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_formatting.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_section_title.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// The running bill for a blending session.
///
/// A fill station rarely does one cylinder. Without this the blender has to
/// write each finished fill down on paper before starting the next, because
/// the next blend replaces the one on screen (issue #1100).
class BlenderInvoiceCard extends ConsumerStatefulWidget {
  const BlenderInvoiceCard({super.key});

  @override
  ConsumerState<BlenderInvoiceCard> createState() => _BlenderInvoiceCardState();
}

class _BlenderInvoiceCardState extends ConsumerState<BlenderInvoiceCard> {
  late final TextEditingController _billedTo;
  late final List<TextEditingController> _flushVolumes;

  /// The logbook name is a starting point, offered once. Re-seeding on every
  /// rebuild would fight the diver as they typed a customer's name.
  bool _seededBilledTo = false;

  @override
  void initState() {
    super.initState();
    _billedTo = TextEditingController(text: ref.read(blenderBilledToProvider));
    final settings = ref.read(settingsProvider);
    _flushVolumes = [
      for (final g in ref.read(blenderFlushFeeGasesProvider))
        TextEditingController(
          text: formatRoundedForInput(
            blenderDisplayVolume(g.volumeLiters, settings),
            2,
          ),
        ),
    ];
  }

  @override
  void dispose() {
    _billedTo.dispose();
    for (final c in _flushVolumes) {
      c.dispose();
    }
    super.dispose();
  }

  /// Fill in [name] the first time one is available and the field is still
  /// untouched. Scheduled off the build because it writes provider state.
  void _seedBilledTo(String name) {
    if (name.isEmpty || _seededBilledTo) return;
    if (ref.read(blenderBilledToProvider).isNotEmpty) {
      _seededBilledTo = true;
      return;
    }
    _seededBilledTo = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(blenderBilledToProvider).isNotEmpty) return;
      ref.read(blenderBilledToProvider.notifier).state = name;
      _billedTo.text = name;
    });
  }

  @override
  Widget build(BuildContext context) {
    final fills = ref.watch(blenderBilledFillsProvider);
    final currency = ref.watch(blenderCurrencyProvider);
    final settings = ref.watch(settingsProvider);
    final units = UnitFormatter(settings);
    final decimals = pressureDecimalsFor(settings.pressureUnit);
    final theme = Theme.of(context);

    final flushEnabled = ref.watch(blenderFlushFeeEnabledProvider);
    final flushMode = ref.watch(blenderFlushFeeModeProvider);
    final flushGases = ref.watch(blenderFlushFeeGasesProvider);
    // "Once per bill" always shows once the fee is on, even before the first
    // fill: it is a session setup cost, not tied to any one cylinder. "Once
    // per fill" has nothing to charge yet when nothing has been filled.
    final flushMultiplier = flushMode == FlushFeeMode.perInvoice
        ? 1
        : fills.length;
    final showFlush = flushEnabled && flushMultiplier > 0;

    final fillsTotal = totalOf(fills);
    var flushAmount = 0.0;
    var flushComplete = true;
    if (showFlush) {
      for (final g in flushGases) {
        final cost = flushFeeCost(
          g.volumeLiters * flushMultiplier,
          g.pricePer100,
        );
        if (cost == null) {
          flushComplete = false;
        } else {
          flushAmount += cost;
        }
      }
    }
    final total = BilledTotal(
      amount: fillsTotal.amount + flushAmount,
      complete: fillsTotal.complete && flushComplete,
    );

    // Seed the name from the logbook, once, and only when the diver has not
    // typed one. A fill station fills other people's cylinders, so this is a
    // starting point rather than a fixed label.
    //
    // Watched, not listened to: currentDiverProvider is resolved long before
    // anyone opens the calculators tab, and ref.listen fires only on a later
    // change, so the listener never ran in the real app (PR #1215 review).
    final diver = ref.watch(currentDiverProvider).valueOrNull;
    _seedBilledTo(diver?.name.trim() ?? '');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BlenderSectionTitle(context.l10n.gasCalculators_blender_billed),
            TextField(
              controller: _billedTo,
              decoration: InputDecoration(
                labelText: context.l10n.gasCalculators_blender_billedTo,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) =>
                  ref.read(blenderBilledToProvider.notifier).state = v,
              onEditingComplete: () => saveBlenderPreferences(ref),
              onSubmitted: (_) => saveBlenderPreferences(ref),
            ),
            const SizedBox(height: 16),
            if (fills.isEmpty && !showFlush)
              Text(
                context.l10n.gasCalculators_blender_billedNone,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else ...[
              if (showFlush) ...[
                for (var i = 0; i < FlushFeeGasKind.values.length; i++)
                  _flushFeeLine(
                    context,
                    i,
                    flushGases[i],
                    flushMultiplier,
                    currency,
                    units,
                    settings,
                  ),
                const SizedBox(height: 4),
              ],
              for (final f in fills)
                _fillLine(context, f, currency, units, decimals),
            ],
            const SizedBox(height: 8),
            // A Wrap so the two actions drop to separate lines on the
            // narrowest phone rather than overflowing.
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton.icon(
                  key: const Key('blender-add-manual-line'),
                  onPressed: () => _editLine(null),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(
                    context.l10n.gasCalculators_blender_addManualLine,
                  ),
                ),
                if (fills.isNotEmpty)
                  TextButton(
                    key: const Key('blender-clear-billed'),
                    onPressed: _confirmClear,
                    child: Text(
                      context.l10n.gasCalculators_blender_clearBilled,
                    ),
                  ),
              ],
            ),
            if (fills.isNotEmpty || showFlush) ...[
              const Divider(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    context.l10n.gasCalculators_blender_billedTotal,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    formatMoney(total.amount, currency),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              if (!total.complete)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    context.l10n.gasCalculators_blender_billedIncomplete,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// One structured flush-fee line: the gas, its editable purge volume, and
  /// what that volume costs at the configured rate. Derived from settings
  /// rather than stored in [blenderBilledFillsProvider] — nothing in that
  /// append-only list is "first" by construction, so a fee meant to sit once
  /// at the top of the bill has to live outside it (issue #1335).
  Widget _flushFeeLine(
    BuildContext context,
    int index,
    FlushFeeGasSetting gas,
    int multiplier,
    String currency,
    UnitFormatter units,
    AppSettings settings,
  ) {
    final kind = FlushFeeGasKind.values[index];
    final label = flushFeeGasLabel(context, kind);
    final cost = flushFeeCost(gas.volumeLiters * multiplier, gas.pricePer100);
    final style = Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 3,
            child: Text(
              multiplier > 1 ? '$label  ×$multiplier' : label,
              style: style,
            ),
          ),
          SizedBox(
            width: 72,
            child: TextField(
              key: Key('blender-flush-fee-liters-${kind.name}'),
              controller: _flushVolumes[index],
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              decoration: InputDecoration(
                isDense: true,
                suffixText: units.volumeSymbol,
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) {
                final gases = [...ref.read(blenderFlushFeeGasesProvider)];
                gases[index] = gases[index].copyWith(
                  volumeLiters: blenderLitersFromDisplay(
                    parseUserDecimal(v) ?? 0,
                    settings,
                  ),
                );
                ref.read(blenderFlushFeeGasesProvider.notifier).state = gases;
              },
              onEditingComplete: () => saveBlenderPreferences(ref),
              onSubmitted: (_) => saveBlenderPreferences(ref),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: Text(
              cost == null ? '' : formatMoney(cost, currency),
              style: style,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }

  Widget _fillLine(
    BuildContext context,
    BilledFill fill,
    String currency,
    UnitFormatter units,
    int decimals,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                flex: 2,
                child: Text(
                  fill.label,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Flexible(
                child: Text(
                  fill.total == null ? '' : formatMoney(fill.total!, currency),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Compact so a label, an amount and two actions still fit the
              // narrowest phone the app supports.
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 18),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: context.l10n.gasCalculators_blender_editLine(
                  fill.label,
                ),
                onPressed: () => _editLine(fill),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: context.l10n.gasCalculators_blender_deleteLine(
                  fill.label,
                ),
                onPressed: () => _delete(fill),
              ),
            ],
          ),
          // The itemisation is what makes the total checkable at the counter,
          // so it stays visible rather than hiding behind a disclosure.
          for (final line in fill.lines)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2),
              child: Row(
                children: [
                  Expanded(
                    flex: 4,
                    child: Text(line.gas, style: theme.textTheme.bodySmall),
                  ),
                  Expanded(
                    flex: 4,
                    child: Text(
                      units.formatPressure(line.addedBar, decimals: decimals),
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.end,
                    ),
                  ),
                  Expanded(
                    flex: 4,
                    child: Text(
                      line.cost == null
                          ? ''
                          : formatMoney(line.cost!, currency),
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
            ),
          if (fill.customMix case final mix?)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2),
              child: Text(
                '${units.formatVolume(mix.cylinderLiters)} · '
                '${formatPreciseMix(context, GasMix(o2: mix.o2, he: mix.he))}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _delete(BilledFill fill) {
    ref.read(blenderBilledFillsProvider.notifier).state = [
      ...ref.read(blenderBilledFillsProvider).where((f) => f.id != fill.id),
    ];
    saveBlenderPreferences(ref);
  }

  /// Edit an existing line, or add a manual one when [fill] is null.
  ///
  /// The amount stays editable on computed fills too: rounding and the
  /// occasional discount happen at a real counter, and re-blending the
  /// cylinder to change what it costs would be absurd.
  Future<void> _editLine(BilledFill? fill) async {
    final edited = await showModalBottomSheet<_LineEdit>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _LineEditSheet(fill: fill),
    );
    if (edited == null) return;

    final fills = ref.read(blenderBilledFillsProvider);
    if (fill == null) {
      ref.read(blenderBilledFillsProvider.notifier).state = appendCapped(
        fills,
        BilledFill(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          label: edited.label,
          lines: const [],
          total: edited.amount,
          customMix: edited.customMix,
        ),
      );
    } else {
      ref.read(blenderBilledFillsProvider.notifier).state = [
        for (final f in fills)
          if (f.id == fill.id)
            f.copyWith(
              label: edited.label,
              total: edited.amount,
              clearTotal: edited.amount == null,
              customMix: edited.customMix,
              clearCustomMix: edited.customMix == null,
            )
          else
            f,
      ];
    }
    saveBlenderPreferences(ref);
  }

  Future<void> _confirmClear() async {
    final count = ref.read(blenderBilledFillsProvider).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.gasCalculators_blender_clearBilledTitle),
        content: Text(
          context.l10n.gasCalculators_blender_clearBilledBody(count),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.common_action_close),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.gasCalculators_blender_clearBilled),
          ),
        ],
      ),
    );
    if (ok != true) return;
    ref.read(blenderBilledFillsProvider.notifier).state = const [];
    saveBlenderPreferences(ref);
  }
}

/// What the edit sheet hands back.
class _LineEdit {
  const _LineEdit({required this.label, required this.amount, this.customMix});
  final String label;
  final double? amount;
  final BilledCustomMix? customMix;
}

/// Owns its own controllers, and disposes them in its own State.
///
/// Creating them in the caller and disposing on the sheet's future looks
/// equivalent and is not: the future completes when the route is popped, while
/// the exit transition keeps rebuilding these fields for several more frames
/// against a controller that is already gone.
///
/// A scrollable, keyboard-aware bottom sheet rather than the fixed-size
/// `AlertDialog` this replaced: a cylinder row and an O2/He row roughly
/// double the field count, and a taller fixed dialog risks overflow once the
/// keyboard is up on the narrowest phone the app supports (issue #1335).
class _LineEditSheet extends ConsumerStatefulWidget {
  const _LineEditSheet({required this.fill});

  final BilledFill? fill;

  @override
  ConsumerState<_LineEditSheet> createState() => _LineEditSheetState();
}

class _LineEditSheetState extends ConsumerState<_LineEditSheet> {
  late final TextEditingController _label;
  late final TextEditingController _amount;
  late final TextEditingController _cylinder;
  late final TextEditingController _o2;
  late final TextEditingController _he;

  /// Only a new line or one that is still a manual/custom-mix entry offers
  /// the cylinder and mix fields. A computed fill's gases are already
  /// itemised in [BilledFill.lines]; editing them here would let the label
  /// and the itemisation disagree.
  bool get _showMix => widget.fill == null || widget.fill!.isManual;

  String? _error;

  @override
  void initState() {
    super.initState();
    final fill = widget.fill;
    final settings = ref.read(settingsProvider);
    _label = TextEditingController(text: fill?.label ?? '');
    _amount = TextEditingController(
      text: fill?.total == null ? '' : formatRoundedForInput(fill!.total!, 2),
    );
    final mix = fill?.customMix;
    final double cylinderLiters =
        mix?.cylinderLiters ?? ref.read(blenderCylinderLitersProvider);
    _cylinder = TextEditingController(
      text: formatRoundedForInput(
        blenderDisplayVolume(cylinderLiters, settings),
        2,
      ),
    );
    _o2 = TextEditingController(text: formatRoundedForInput(mix?.o2 ?? 21, 1));
    _he = TextEditingController(text: formatRoundedForInput(mix?.he ?? 0, 1));
  }

  @override
  void dispose() {
    _label.dispose();
    _amount.dispose();
    _cylinder.dispose();
    _o2.dispose();
    _he.dispose();
    super.dispose();
  }

  void _submit() {
    final label = _label.text.trim();
    final amount = parseUserDecimal(_amount.text);
    BilledCustomMix? customMix;
    if (_showMix) {
      final settings = ref.read(settingsProvider);
      final liters = parseUserDecimal(_cylinder.text);
      final o2 = parseUserDecimal(_o2.text);
      final he = parseUserDecimal(_he.text);
      if (liters != null && o2 != null && he != null) {
        if (!MixTemplate(o2: o2, he: he).isValid) {
          setState(
            () => _error = context.l10n.gasCalculators_blender_error_invalidMix,
          );
          return;
        }
        customMix = BilledCustomMix(
          cylinderLiters: blenderLitersFromDisplay(liters, settings),
          o2: o2,
          he: he,
        );
      }
    }
    final effectiveLabel = label.isNotEmpty
        ? label
        : customMix != null
        ? formatPreciseMix(context, GasMix(o2: customMix.o2, he: customMix.he))
        : '';
    if (effectiveLabel.isEmpty) return;
    Navigator.of(context).pop(
      _LineEdit(label: effectiveLabel, amount: amount, customMix: customMix),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fill = widget.fill;
    final settings = ref.watch(settingsProvider);
    final units = UnitFormatter(settings);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              fill == null
                  ? context.l10n.gasCalculators_blender_addManualLine
                  : context.l10n.gasCalculators_blender_editLine(fill.label),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('blender-line-description'),
              controller: _label,
              autofocus: true,
              decoration: InputDecoration(
                labelText: context.l10n.gasCalculators_blender_lineDescription,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            if (_showMix) ...[
              _cylinderRow(context, settings, units),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _numberField(
                      context,
                      _o2,
                      context.l10n.gasCalculators_blender_o2,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _numberField(
                      context,
                      _he,
                      context.l10n.gasCalculators_blender_he,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              key: const Key('blender-line-amount'),
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: context.l10n.gasCalculators_blender_lineAmount,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _submit,
              child: Text(context.l10n.common_action_save),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cylinderRow(
    BuildContext context,
    AppSettings settings,
    UnitFormatter units,
  ) {
    final choices = blenderTankChoices();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            key: const Key('blender-line-cylinder'),
            controller: _cylinder,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
            ],
            decoration: InputDecoration(
              labelText:
                  '${context.l10n.gasCalculators_blender_cylinderVolume} '
                  '(${units.volumeSymbol})',
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        PopupMenuButton<TankSpec>(
          key: const Key('blender-line-cylinder-presets'),
          tooltip: context.l10n.gasCalculators_blender_cylinderPresets,
          position: PopupMenuPosition.under,
          itemBuilder: (context) => [
            for (final choice in choices)
              PopupMenuItem<TankSpec>(
                value: choice,
                child: Text(
                  units.formatTankVolume(
                    choice.waterVolumeLiters,
                    choice.workingPressureBar,
                    ratedCapacityCuft: choice.ratedCapacityCuft,
                  ),
                ),
              ),
          ],
          onSelected: (choice) => setState(
            () => _cylinder.text = formatRoundedForInput(
              blenderDisplayVolume(choice.waterVolumeLiters, settings),
              2,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(context.l10n.gasCalculators_blender_cylinderPresets),
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _numberField(
    BuildContext context,
    TextEditingController controller,
    String label,
  ) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
      decoration: InputDecoration(
        labelText: '$label (%)',
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    );
  }
}
