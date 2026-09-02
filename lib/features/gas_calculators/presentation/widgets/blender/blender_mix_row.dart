import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// A row of pressure (optional) plus O2 plus He fields.
///
/// The unit lives in the label rather than in `suffixText`. A suffix costs
/// roughly 30 logical pixels inside the field, which on a phone is the
/// difference between showing "65.9" and clipping it. Below [_stackBelow] the
/// pressure field takes its own line instead of sharing one with two
/// percentages.
class BlenderMixRow extends StatelessWidget {
  const BlenderMixRow({
    super.key,
    this.leading,
    this.leadingWidth,
    this.pressureController,
    this.onPressure,
    required this.o2Controller,
    required this.heController,
    required this.onMix,
    required this.pressureSymbol,
    this.onSave,
    this.errorText,
  });

  static const double _stackBelow = 420;

  final String? leading;

  /// A shared width for [leading] across a set of rows, so the O2/He fields
  /// line up regardless of how long each row's gas name happens to be.
  /// Natural (text-sized) width when null.
  final double? leadingWidth;

  final TextEditingController? pressureController;
  final ValueChanged<String>? onPressure;
  final TextEditingController o2Controller;
  final TextEditingController heController;
  final VoidCallback onMix;
  final String pressureSymbol;

  /// Fired on blur/submit of any field in the row, not per keystroke -- the
  /// same debounce every other persisted blender field uses. Null when the
  /// row's values are not persisted.
  final VoidCallback? onSave;

  /// Shown under both the O2 and He fields when set. The two fractions are
  /// only ever invalid together (negative, or summing past 100%), so there is
  /// no single field to pin the message to.
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked =
            pressureController != null && constraints.maxWidth < _stackBelow;
        final percentages = Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: _o2Field(context)),
            const SizedBox(width: 8),
            Expanded(child: _heField(context)),
          ],
        );

        if (stacked) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (leading != null) _leadingLabel(context),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _pressureField(context),
                    const SizedBox(height: 8),
                    percentages,
                  ],
                ),
              ),
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (leading != null) _leadingLabel(context),
            if (pressureController != null) ...[
              Expanded(flex: 4, child: _pressureField(context)),
              const SizedBox(width: 8),
            ],
            Expanded(flex: 3, child: _o2Field(context)),
            const SizedBox(width: 8),
            Expanded(flex: 3, child: _heField(context)),
          ],
        );
      },
    );
  }

  Widget _leadingLabel(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8, bottom: 14),
    child: SizedBox(
      width: leadingWidth,
      child: Text(leading!, style: Theme.of(context).textTheme.titleSmall),
    ),
  );

  Widget _pressureField(BuildContext context) => _field(
    controller: pressureController!,
    label: '${context.l10n.gasCalculators_blender_pressure} ($pressureSymbol)',
    onChanged: onPressure!,
  );

  Widget _o2Field(BuildContext context) => _field(
    controller: o2Controller,
    label: '${context.l10n.gasCalculators_blender_o2} (%)',
    onChanged: (_) => onMix(),
  );

  Widget _heField(BuildContext context) => _field(
    controller: heController,
    label: '${context.l10n.gasCalculators_blender_he} (%)',
    onChanged: (_) => onMix(),
  );

  Widget _field({
    required TextEditingController controller,
    required String label,
    required ValueChanged<String> onChanged,
  }) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
      decoration: InputDecoration(
        labelText: label,
        errorText: errorText,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      onChanged: onChanged,
      onEditingComplete: onSave,
      onSubmitted: onSave == null ? null : (_) => onSave!(),
    );
  }
}
