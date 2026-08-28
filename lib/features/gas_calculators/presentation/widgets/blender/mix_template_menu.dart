import 'package:flutter/material.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart'
    show GasMix;
import 'package:submersion/features/gas_calculators/domain/blending/blender_preferences.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// Saved target mixes, offered as a menu beside the target fill fields.
///
/// A blender repeats the same handful of mixes, so retyping 10/70 on every
/// fill is the friction this removes. Templates carry a mix only: the same mix
/// gets blended into different cylinders at different pressures.
///
/// A plain picker onto whatever is saved (issue #1335 follow-up): adding,
/// editing and deleting templates now happens only under Settings -> Trimix
/// Mixer, not from this menu.
class MixTemplateMenu extends ConsumerWidget {
  const MixTemplateMenu({super.key, required this.onSelected});

  /// Called after the target mix providers are updated, so the caller can
  /// re-seed its text controllers.
  final void Function(MixTemplate) onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final templates = ref.watch(blenderTemplatesProvider);

    return PopupMenuButton<MixTemplate>(
      tooltip: context.l10n.gasCalculators_blender_templates,
      position: PopupMenuPosition.under,
      itemBuilder: (context) => [
        if (templates.isEmpty)
          PopupMenuItem<MixTemplate>(
            enabled: false,
            child: Text(context.l10n.gasCalculators_blender_templateNone),
          )
        else
          for (final t in templates)
            PopupMenuItem<MixTemplate>(value: t, child: Text(t.label)),
      ],
      onSelected: (value) {
        ref.read(blenderTargetMixProvider.notifier).state = GasMix(
          o2: value.o2,
          he: value.he,
        );
        onSelected(value);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(context.l10n.gasCalculators_blender_templates),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}
