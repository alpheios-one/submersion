import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/utils/number_input.dart';
import 'package:submersion/features/gas_calculators/domain/blending/blender_preferences.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// Add and delete saved target mixes.
Future<void> showMixTemplateDialog(BuildContext context, WidgetRef ref) {
  return showDialog<void>(
    context: context,
    builder: (context) => _MixTemplateDialog(parentRef: ref),
  );
}

class _MixTemplateDialog extends StatefulWidget {
  const _MixTemplateDialog({required this.parentRef});

  /// The dialog opens in its own route, above the ProviderScope's consumer, so
  /// it borrows the opener's ref rather than reaching for a new one.
  final WidgetRef parentRef;

  @override
  State<_MixTemplateDialog> createState() => _MixTemplateDialogState();
}

class _MixTemplateDialogState extends State<_MixTemplateDialog> {
  final _o2 = TextEditingController();
  final _he = TextEditingController();

  @override
  void dispose() {
    _o2.dispose();
    _he.dispose();
    super.dispose();
  }

  WidgetRef get _ref => widget.parentRef;

  void _add() {
    final o2 = parseUserDecimal(_o2.text);
    final he = parseUserDecimal(_he.text);
    if (o2 == null || he == null) return;
    final candidate = MixTemplate(o2: o2, he: he);
    final existing = _ref.read(blenderTemplatesProvider);
    if (!candidate.isValid ||
        existing.contains(candidate) ||
        existing.length >= BlenderPreferences.maxTemplates) {
      return;
    }
    setState(() {
      _ref.read(blenderTemplatesProvider.notifier).state = [
        ...existing,
        candidate,
      ];
    });
    saveBlenderPreferences(_ref);
    _o2.clear();
    _he.clear();
  }

  void _delete(MixTemplate t) {
    setState(() {
      _ref.read(blenderTemplatesProvider.notifier).state = [
        ..._ref.read(blenderTemplatesProvider).where((x) => x != t),
      ];
    });
    saveBlenderPreferences(_ref);
  }

  @override
  Widget build(BuildContext context) {
    final templates = _ref.watch(blenderTemplatesProvider);
    return AlertDialog(
      title: Text(context.l10n.gasCalculators_blender_templatesTitle),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (templates.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(context.l10n.gasCalculators_blender_templateNone),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final t in templates)
                      ListTile(
                        dense: true,
                        title: Text(t.label),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: context.l10n
                              .gasCalculators_blender_templateDelete(t.label),
                          onPressed: () => _delete(t),
                        ),
                      ),
                  ],
                ),
              ),
            const Divider(),
            Row(
              children: [
                Expanded(child: _numberField(_o2, 'O₂')),
                const SizedBox(width: 8),
                Expanded(child: _numberField(_he, 'He')),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: context.l10n.gasCalculators_blender_templateAdd,
                  onPressed: _add,
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.common_action_close),
        ),
      ],
    );
  }

  Widget _numberField(TextEditingController controller, String label) {
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
