// A flush/purge fee for clearing the fill hose before drawing a gas.
//
// Kept separate from BlenderPreferences.gasPrices: that list prices whatever
// bank a diver has wired a gas to, while a hose only needs purging for the
// gas actually connected to it. This is keyed by gas identity (oxygen,
// helium, air) rather than by bank position.

/// The three gas identities a flush fee can be configured for. Fixed rather
/// than open-ended: a fill station purges for oxygen, helium and air, not for
/// an arbitrary blend.
enum FlushFeeGasKind { o2, he, air }

/// How often the configured flush fee appears on the bill.
enum FlushFeeMode {
  /// Once per billing session, regardless of how many fills were saved. A
  /// hose is purged once when a gas source is connected, not on every fill
  /// drawn from it afterwards.
  perInvoice,

  /// Once for every fill saved to the bill.
  perFill;

  static FlushFeeMode fromName(String? name) => switch (name) {
    'perFill' => FlushFeeMode.perFill,
    _ => FlushFeeMode.perInvoice,
  };
}

/// One gas's flush-fee configuration: the volume purged and its price.
///
/// [volumeLiters] is a starting point, not a fixed amount: the invoice line
/// it seeds stays independently editable, the same way [BilledFill.total]
/// stays editable apart from [BilledFill.lines].
class FlushFeeGasSetting {
  const FlushFeeGasSetting({required this.volumeLiters, this.pricePer100});

  final double volumeLiters;

  /// Price per 100 litres, same convention as [BlenderPreferences.gasPrices].
  /// Null means the diver has not priced this gas's flush fee.
  final double? pricePer100;

  FlushFeeGasSetting copyWith({
    double? volumeLiters,
    double? pricePer100,
    bool clearPrice = false,
  }) => FlushFeeGasSetting(
    volumeLiters: volumeLiters ?? this.volumeLiters,
    pricePer100: clearPrice ? null : (pricePer100 ?? this.pricePer100),
  );

  Map<String, dynamic> toJson() => {
    'volumeLiters': volumeLiters,
    if (pricePer100 != null) 'pricePer100': pricePer100,
  };

  static FlushFeeGasSetting fromJson(
    Object? json, {
    required double defaultVolumeLiters,
  }) {
    if (json is! Map) {
      return FlushFeeGasSetting(volumeLiters: defaultVolumeLiters);
    }
    return FlushFeeGasSetting(
      volumeLiters: _toDouble(json['volumeLiters']) ?? defaultVolumeLiters,
      pricePer100: _toDouble(json['pricePer100']),
    );
  }
}

/// The default per-gas settings a fresh install starts with: enough to purge
/// a hose, unpriced until the diver enters a rate.
const List<FlushFeeGasSetting> defaultFlushFeeGases = [
  FlushFeeGasSetting(volumeLiters: 20),
  FlushFeeGasSetting(volumeLiters: 20),
  FlushFeeGasSetting(volumeLiters: 20),
];

/// What one gas's flush fee costs for [volumeLiters], or null when unpriced.
double? flushFeeCost(double volumeLiters, double? pricePer100) =>
    pricePer100 == null ? null : volumeLiters / 100 * pricePer100;

double? _toDouble(Object? value) => value is num ? value.toDouble() : null;
