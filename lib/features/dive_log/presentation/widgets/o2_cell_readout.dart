/// Tooltip formatting for individual CCR O2 cells.
///
/// A cell can report a partial pressure, a raw millivolt output, or both. The
/// millivolt-only case is issue #810: the computer logged a factory-default
/// calibration, so libdivecomputer withholds the conversion rather than anchor
/// it to a placeholder, and only the measurement survives.
library;

/// One tooltip row's value for a single cell, or null when the cell reported
/// nothing at this sample.
String? formatO2CellReadout({required double? bar, required int? millivolt}) {
  if (bar == null && millivolt == null) return null;
  if (bar == null) return '$millivolt mV';
  if (millivolt == null) return '${bar.toStringAsFixed(2)} bar';
  return '${bar.toStringAsFixed(2)} bar ($millivolt mV)';
}

/// How many physical cells to render rows for: the two curve sets can differ in
/// length when one carries a cell the other does not.
int o2CellCount({
  required List<List<double?>>? barCurves,
  required List<List<int?>>? mvCurves,
}) {
  final bars = barCurves?.length ?? 0;
  final mvs = mvCurves?.length ?? 0;
  return bars > mvs ? bars : mvs;
}

/// Reads one cell's value at one sample, tolerating curve sets that are shorter
/// than the cell index or the sample index.
T? valueAtSample<T>({
  required List<List<T?>>? curves,
  required int cell,
  required int sampleIndex,
}) {
  if (curves == null || cell >= curves.length) return null;
  final curve = curves[cell];
  if (sampleIndex >= curve.length) return null;
  return curve[sampleIndex];
}
