import 'package:flutter/material.dart';
import 'package:submersion/core/utils/currency.dart';
import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/gas_calculators/domain/blending/billed_fill.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// The flex ratios [BlenderBilledLineRow] and [BlenderBilledLineHeader] share,
/// so the header's units line up over the values they label.
const List<int> _kBilledLineFlex = [3, 3, 3, 3, 3];

/// The column header for a block of [BlenderBilledLineRow]s, units included
/// so they are not repeated on every line (issue #1876). Shown once above
/// each fill's itemisation, in [BlenderInvoiceCard] and the read-only archive
/// detail view.
class BlenderBilledLineHeader extends StatelessWidget {
  const BlenderBilledLineHeader({super.key, required this.units});

  final UnitFormatter units;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 2, bottom: 2),
      child: Row(
        children: [
          Expanded(
            flex: _kBilledLineFlex[0],
            child: Text(
              l10n.gasCalculators_blender_flushFeeColumnGas,
              style: style,
            ),
          ),
          Expanded(
            flex: _kBilledLineFlex[1],
            child: Text(
              '${l10n.gasCalculators_blender_stepColumnAdded} '
              '(${units.pressureSymbol})',
              style: style,
              textAlign: TextAlign.end,
            ),
          ),
          Expanded(
            flex: _kBilledLineFlex[2],
            child: Text(
              units.volumeSymbol,
              style: style,
              textAlign: TextAlign.end,
            ),
          ),
          Expanded(
            flex: _kBilledLineFlex[3],
            child: Text(
              l10n.gasCalculators_blender_cylinderVolume,
              style: style,
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: _kBilledLineFlex[4],
            child: Text('', style: style, textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }
}

/// One gas/volume/cylinder/cost row of an itemised fill, shared by the
/// running bill ([BlenderInvoiceCard]) and the read-only archive detail view:
/// both show exactly the same columns, and a second copy of the
/// volume-vs-pressure fallback in the archive view is how that logic would
/// drift out of step with the running bill's (see [BilledGasLine.freeGasLiters]).
class BlenderBilledLineRow extends StatelessWidget {
  const BlenderBilledLineRow({
    super.key,
    required this.line,
    required this.currency,
    required this.units,
    required this.decimals,
  });

  final BilledGasLine line;
  final String currency;
  final UnitFormatter units;
  final int decimals;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 2),
      child: Row(
        children: [
          Expanded(
            flex: _kBilledLineFlex[0],
            child: Text(line.gas, style: style),
          ),
          Expanded(
            flex: _kBilledLineFlex[1],
            child: Text(
              '+${units.formatPressureValue(line.addedBar, decimals: decimals)}',
              style: style,
              textAlign: TextAlign.end,
            ),
          ),
          Expanded(
            flex: _kBilledLineFlex[2],
            child: Text(
              // Volume when this line has one (every fill saved since
              // #1335); pressure-only rows saved before that fall back to a
              // dash, since their volume was never kept and the "Hinzufügen"
              // column already shows the pressure delta.
              line.freeGasLiters != null
                  ? units.formatVolumeValue(line.freeGasLiters!)
                  : '—',
              style: style,
              textAlign: TextAlign.end,
            ),
          ),
          Expanded(
            flex: _kBilledLineFlex[3],
            child: Text(
              line.cylinderLiters != null
                  ? units.formatVolumeValue(line.cylinderLiters!)
                  : '—',
              style: style,
              textAlign: TextAlign.end,
            ),
          ),
          Expanded(
            flex: _kBilledLineFlex[4],
            child: Text(
              line.cost == null ? '' : formatMoney(line.cost!, currency),
              style: style,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}
