import 'package:flutter/material.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/utils/number_input.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_conditions_card.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_defaults_card.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_fill_gases_card.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_volume_conversion.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/mix_template_manager.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// The Trimix Mixer's own settings, reached both from the calculator's
/// settings gear and from the global Settings page (issue #1335 follow-up):
/// fill gases, mixing conditions, saved target-fill mixes, and billing
/// defaults, kept off the always-visible calculator so the fields a diver
/// sets once per session don't compete with the ones they retype every fill.
class BlenderSettingsPage extends ConsumerWidget {
  const BlenderSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Settings > Manage > Data reaches this page on its own route, so the
    // calculator -- until now the only thing that started the load -- never
    // mounts. Without this watch every card below shows a hard-coded default,
    // and because saving writes the whole preferences blob at once, the first
    // edit here would take the diver's saved mixes, billed fills and
    // last-entered pressures down with it.
    ref.watch(blenderPreferencesLoaderProvider);
    // The load resolves after the first build and bumps the epoch. Re-keying
    // on it rebuilds the body, and with it the controllers each card seeds in
    // its own initState, onto the freshly loaded values -- the same contract
    // the calculator uses for its own fields.
    final epoch = ref.watch(blenderResetEpochProvider);
    return _BlenderSettingsBody(key: ValueKey(epoch));
  }
}

class _BlenderSettingsBody extends ConsumerStatefulWidget {
  const _BlenderSettingsBody({super.key});

  @override
  ConsumerState<_BlenderSettingsBody> createState() =>
      _BlenderSettingsBodyState();
}

class _BlenderSettingsBodyState extends ConsumerState<_BlenderSettingsBody> {
  late final List<TextEditingController> _gasO2;
  late final List<TextEditingController> _gasHe;
  late final List<TextEditingController> _gasPrices;

  @override
  void initState() {
    super.initState();
    String n(double v) => formatDecimalForInput(v);

    final g1 = ref.read(blenderFillGas1Provider);
    final g2 = ref.read(blenderFillGas2Provider);
    final g3 = ref.read(blenderFillGas3Provider);

    _gasO2 = [
      TextEditingController(text: n(g1.o2)),
      TextEditingController(text: n(g2.o2)),
      TextEditingController(text: n(g3.o2)),
    ];
    _gasHe = [
      TextEditingController(text: n(g1.he)),
      TextEditingController(text: n(g2.he)),
      TextEditingController(text: n(g3.he)),
    ];

    final settings = ref.read(settingsProvider);
    _gasPrices = [
      for (final p in ref.read(blenderGasPricesProvider))
        TextEditingController(
          text: p == null
              ? ''
              : formatRoundedForInput(
                  pricePer100LitersToDisplay(p, settings),
                  2,
                ),
        ),
    ];
  }

  @override
  void dispose() {
    for (final c in [..._gasO2, ..._gasHe, ..._gasPrices]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.settings_section_trimixMixer_title),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BlenderFillGasesCard(
                  o2Controllers: _gasO2,
                  heControllers: _gasHe,
                  priceControllers: _gasPrices,
                ),
                const SizedBox(height: 16),
                const BlenderConditionsCard(),
                const SizedBox(height: 16),
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: MixTemplateManager(),
                  ),
                ),
                const SizedBox(height: 16),
                const BlenderDefaultsCard(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
