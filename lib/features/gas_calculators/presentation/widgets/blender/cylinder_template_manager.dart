import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/utils/number_input.dart';
import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/gas_calculators/domain/blending/cylinder_template.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_volume_conversion.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// Add and delete cylinder-size templates (name + litres), which then show up
/// alongside the static presets in the blender's cylinder dropdown.
///
/// A section within the settings page rather than a dialog, unlike the mix
/// template manager: the issue places this under "Default settings and
/// billing" as a first-class part of that page, not a menu action.
class CylinderTemplateManager extends ConsumerStatefulWidget {
  const CylinderTemplateManager({super.key});

  @override
  ConsumerState<CylinderTemplateManager> createState() =>
      _CylinderTemplateManagerState();
}

class _CylinderTemplateManagerState
    extends ConsumerState<CylinderTemplateManager> {
  final _name = TextEditingController();
  final _liters = TextEditingController();

  /// The outcome of the last add attempt, shown under the entry row.
  String? _message;

  @override
  void dispose() {
    _name.dispose();
    _liters.dispose();
    super.dispose();
  }

  void _add() {
    final settings = ref.read(settingsProvider);
    final name = _name.text.trim();
    final entered = parseUserDecimal(_liters.text);
    final liters = entered == null
        ? null
        : displayVolumeToLiters(entered, settings);
    final candidate = CylinderTemplate(name: name, liters: liters ?? 0);
    final existing = ref.read(blenderCylinderTemplatesProvider);
    final problem = _describeRejection(
      cylinderTemplateRejectionFor(existing, candidate),
    );
    if (problem != null) {
      setState(() => _message = problem);
      return;
    }
    ref.read(blenderCylinderTemplatesProvider.notifier).state = [
      ...existing,
      candidate,
    ];
    saveBlenderPreferences(ref);
    setState(() => _message = null);
    _name.clear();
    _liters.clear();
  }

  void _delete(CylinderTemplate t) {
    ref.read(blenderCylinderTemplatesProvider.notifier).state = [
      ...ref.read(blenderCylinderTemplatesProvider).where((x) => x != t),
    ];
    saveBlenderPreferences(ref);
  }

  String? _describeRejection(CylinderTemplateRejection? rejection) =>
      switch (rejection) {
        null => null,
        CylinderTemplateRejection.invalid =>
          context.l10n.gasCalculators_blender_cylinderTemplateInvalid,
        CylinderTemplateRejection.duplicate =>
          context.l10n.gasCalculators_blender_cylinderTemplateExists,
        CylinderTemplateRejection.limitReached =>
          context.l10n.gasCalculators_blender_cylinderTemplateLimit,
      };

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final units = UnitFormatter(settings);
    final templates = ref.watch(blenderCylinderTemplatesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.gasCalculators_blender_cylinderTemplates,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        if (templates.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              context.l10n.gasCalculators_blender_cylinderTemplateNone,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          )
        else
          for (final t in templates)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(t.name),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(units.formatTankVolume(t.liters, null)),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: context.l10n.common_action_delete,
                    onPressed: () => _delete(t),
                  ),
                ],
              ),
            ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Text(
              _message!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _name,
                decoration: InputDecoration(
                  labelText:
                      context.l10n.gasCalculators_blender_cylinderTemplateName,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _liters,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
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
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: context.l10n.common_action_add,
              onPressed: _add,
            ),
          ],
        ),
      ],
    );
  }
}
