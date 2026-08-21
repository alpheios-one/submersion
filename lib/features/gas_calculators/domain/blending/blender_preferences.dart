import 'package:submersion/features/gas_calculators/domain/blending/equation_of_state.dart';

/// A saved target mix, e.g. 10/70. Pressure is deliberately not part of a
/// template: blenders reuse a mix across cylinders and fill pressures.
class MixTemplate {
  const MixTemplate({required this.o2, required this.he});

  final double o2;
  final double he;

  bool get isValid => o2 >= 0 && he >= 0 && o2 + he <= 100;

  /// "10/70", trimming a trailing ".0" so whole percentages read cleanly.
  String get label => '${_trim(o2)}/${_trim(he)}';

  static String _trim(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  Map<String, dynamic> toJson() => {'o2': o2, 'he': he};

  static MixTemplate? fromJson(Object? json) {
    if (json is! Map) return null;
    final o2 = _toDouble(json['o2']);
    final he = _toDouble(json['he']);
    if (o2 == null || he == null) return null;
    final t = MixTemplate(o2: o2, he: he);
    return t.isValid ? t : null;
  }

  @override
  bool operator ==(Object other) =>
      other is MixTemplate && other.o2 == o2 && other.he == he;

  @override
  int get hashCode => Object.hash(o2, he);

  @override
  String toString() => 'MixTemplate($label)';
}

/// Everything the blender remembers between sessions.
///
/// Stored as one JSON object in the `settings` key-value table rather than as
/// columns, so it costs no schema version and still syncs across devices
/// through the existing pending-record path.
class BlenderPreferences {
  const BlenderPreferences({
    required this.templates,
    required this.gasPrices,
    required this.currencyCode,
    required this.fillTempC,
    required this.settledTempC,
    required this.cylinderWaterLiters,
    required this.model,
  });

  /// Enough to keep a synced blob small. Nobody blends 50 distinct mixes.
  static const int maxTemplates = 50;

  /// The mixes named in issue #1100, seeded on first use only. A user who
  /// deletes all of them keeps an empty list, because seeding keys on the
  /// absence of the whole blob rather than on an empty list.
  static const List<MixTemplate> seedTemplates = [
    MixTemplate(o2: 7, he: 75),
    MixTemplate(o2: 10, he: 70),
    MixTemplate(o2: 12, he: 60),
    MixTemplate(o2: 15, he: 55),
    MixTemplate(o2: 18, he: 35),
  ];

  final List<MixTemplate> templates;

  /// Price per 100 litres of free gas, positional against the three fill gas
  /// slots. Null means the diver has not priced that gas.
  final List<double?> gasPrices;

  /// Null inherits the diver's `defaultCurrency` setting.
  final String? currencyCode;

  final double fillTempC;
  final double settledTempC;
  final double cylinderWaterLiters;
  final BlendGasModel model;

  factory BlenderPreferences.defaults({required double cylinderWaterLiters}) =>
      BlenderPreferences(
        templates: seedTemplates,
        gasPrices: const [null, null, null],
        currencyCode: null,
        fillTempC: kReferenceTempC,
        settledTempC: kReferenceTempC,
        cylinderWaterLiters: cylinderWaterLiters,
        model: BlendGasModel.zFactor,
      );

  BlenderPreferences copyWith({
    List<MixTemplate>? templates,
    List<double?>? gasPrices,
    String? currencyCode,
    double? fillTempC,
    double? settledTempC,
    double? cylinderWaterLiters,
    BlendGasModel? model,
  }) => BlenderPreferences(
    templates: (templates ?? this.templates).take(maxTemplates).toList(),
    gasPrices: gasPrices ?? this.gasPrices,
    currencyCode: currencyCode ?? this.currencyCode,
    fillTempC: fillTempC ?? this.fillTempC,
    settledTempC: settledTempC ?? this.settledTempC,
    cylinderWaterLiters: cylinderWaterLiters ?? this.cylinderWaterLiters,
    model: model ?? this.model,
  );

  Map<String, dynamic> toJson() => {
    'templates': templates.map((t) => t.toJson()).toList(),
    'gasPrices': gasPrices,
    'currencyCode': currencyCode,
    'fillTempC': fillTempC,
    'settledTempC': settledTempC,
    'cylinderWaterLiters': cylinderWaterLiters,
    'model': model.name,
  };

  /// Every field falls back independently, so one corrupt entry never costs
  /// the diver their whole saved price list.
  factory BlenderPreferences.fromJson(Map<String, dynamic> json) {
    final rawTemplates = json['templates'];
    final templates = rawTemplates is List
        ? rawTemplates
              .map(MixTemplate.fromJson)
              .whereType<MixTemplate>()
              .take(maxTemplates)
              .toList()
        : <MixTemplate>[];

    final rawPrices = json['gasPrices'];
    final prices = <double?>[null, null, null];
    if (rawPrices is List) {
      for (var i = 0; i < 3 && i < rawPrices.length; i++) {
        prices[i] = _toDouble(rawPrices[i]);
      }
    }

    final currency = json['currencyCode'];

    return BlenderPreferences(
      templates: templates,
      gasPrices: prices,
      currencyCode: currency is String && currency.trim().isNotEmpty
          ? currency.trim().toUpperCase()
          : null,
      fillTempC: _toDouble(json['fillTempC']) ?? kReferenceTempC,
      settledTempC: _toDouble(json['settledTempC']) ?? kReferenceTempC,
      cylinderWaterLiters: _toDouble(json['cylinderWaterLiters']) ?? 12.0,
      model: BlendGasModel.fromName(
        json['model'] is String ? json['model'] as String : null,
      ),
    );
  }
}

double? _toDouble(Object? value) {
  if (value is num) return value.toDouble();
  return null;
}
