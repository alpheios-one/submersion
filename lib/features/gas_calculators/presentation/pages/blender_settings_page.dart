import 'package:flutter/material.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/utils/number_input.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_conditions_card.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_defaults_card.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_fill_gases_card.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/mix_template_manager.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// The Trimix Mixer's own settings, reached both from the calculator's
/// settings gear and from the global Settings page (issue #1335 follow-up):
/// fill gases, mixing conditions, saved target-fill mixes, and billing
/// defaults, kept off the always-visible calculator so the fields a diver
/// sets once per session don't compete with the ones they retype every fill.
/// Each card keeps its existing internal layout unchanged.
class BlenderSettingsPage extends ConsumerStatefulWidget {
  const BlenderSettingsPage({super.key});

  @override
  ConsumerState<BlenderSettingsPage> createState() =>
      _BlenderSettingsPageState();
}

class _BlenderSettingsPageState extends ConsumerState<BlenderSettingsPage> {
  late final List<TextEditingController> _gasO2;
  late final List<TextEditingController> _gasHe;

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
  }

  @override
  void dispose() {
    for (final c in [..._gasO2, ..._gasHe]) {
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
