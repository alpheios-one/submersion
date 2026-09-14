import 'package:flutter/services.dart';

/// Limits a decimal field to [maxIntDigits] digits before the separator and
/// [maxFractionDigits] after it, whichever of '.' or ',' the diver types
/// (issue #1876). Every value the mixer's fields hold (percentages, prices,
/// volumes, and pressure once converted to the diver's unit) fits inside a
/// small, known range, so this catches a stray extra digit at the keystroke
/// rather than after the fact.
///
/// Deliberately locale-agnostic about which character is "the" separator:
/// that is [smartParseUserDecimal]'s job once the diver is done typing. This
/// formatter only stops a second separator and stops either side from
/// growing past its digit budget.
class BlenderDecimalDigitsFormatter extends TextInputFormatter {
  const BlenderDecimalDigitsFormatter({
    this.maxIntDigits = 3,
    this.maxFractionDigits = 2,
  });

  final int maxIntDigits;
  final int maxFractionDigits;

  static final _separator = RegExp('[.,]');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    if (text.isEmpty) return newValue;
    if (_separator.allMatches(text).length > 1) return oldValue;

    final sepIndex = text.indexOf(_separator);
    if (sepIndex == -1) {
      return text.length > maxIntDigits ? oldValue : newValue;
    }
    final intDigits = sepIndex;
    final fractionDigits = text.length - sepIndex - 1;
    if (intDigits > maxIntDigits) return oldValue;
    // Exactly three digits after the separator is also the shape of a
    // locale-valid grouped integer (a comma-decimal locale's "4.350" meaning
    // 4350, e.g. a psi pressure) -- smartParseUserDecimal already treats
    // that shape specially (parsing it directly under a locale where it is
    // grouping, and reporting it as genuinely unreadable otherwise), so it
    // is let through here rather than this locale-agnostic formatter
    // rejecting a keystroke the parser would have accepted (issue #1876
    // Copilot review).
    if (fractionDigits > maxFractionDigits && fractionDigits != 3) {
      return oldValue;
    }
    return newValue;
  }
}
