import 'package:submersion/features/dive_log/domain/entities/dive.dart'
    show GasMix;
import 'package:submersion/features/gas_calculators/domain/blending/billed_fill.dart';
import 'package:submersion/features/gas_calculators/domain/blending/cylinder_template.dart';
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

/// Why a target mix cannot be saved as a template.
///
/// Decided here rather than at each call site: the menu and the manage dialog
/// both add templates, and they were disagreeing about whether to explain
/// themselves (PR #1215 review).
enum MixTemplateRejection {
  /// O2 + He over 100%, or a negative fraction.
  invalid,

  /// The same mix is already saved.
  duplicate,

  /// [BlenderPreferences.maxTemplates] reached.
  limitReached,
}

/// Why [candidate] cannot join [existing], or null when it can.
MixTemplateRejection? rejectionFor(
  List<MixTemplate> existing,
  MixTemplate candidate,
) {
  if (!candidate.isValid) return MixTemplateRejection.invalid;
  if (existing.contains(candidate)) return MixTemplateRejection.duplicate;
  if (existing.length >= BlenderPreferences.maxTemplates) {
    return MixTemplateRejection.limitReached;
  }
  return null;
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
    required this.billedFills,
    required this.billedTo,
    required this.startPressureBar,
    required this.startMix,
    required this.targetPressureBar,
    required this.targetMix,
    required this.fillGas1,
    required this.fillGas2,
    required this.fillGas3,
    required this.cylinderTemplates,
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

  /// Cylinders finished and put on the bill, oldest first. A blending session
  /// outlives any one blend, and a fill station doing four cylinders needs the
  /// first three to survive the fourth (issue #1100).
  final List<BilledFill> billedFills;

  /// Who the bill is for. Seeded from the logbook's diver but free text, since
  /// a fill station fills other people's cylinders.
  final String billedTo;

  /// Lives beside [BilledFill] itself; re-exposed here because the JSON read
  /// path enforces it.
  static const int maxBilledFills = kMaxBilledFills;

  /// The starting cylinder pressure and mix, the target fill, and the three
  /// fill gases -- the last-entered values issue #1335 asks to remember
  /// across sessions. Matches the hard-coded defaults the state providers in
  /// `gas_blender_providers.dart` used before persistence existed, so a first
  /// run behaves exactly as it always has.
  final double startPressureBar;
  final GasMix startMix;
  final double targetPressureBar;
  final GasMix targetMix;
  final GasMix fillGas1;
  final GasMix fillGas2;
  final GasMix fillGas3;

  /// User-managed cylinder sizes (name + litres) offered alongside
  /// [blenderTankChoices] in the cylinder dropdown. Empty by default: the
  /// static choices already cover a first run, matching how [templates] seeds
  /// itself only when the whole blob is absent rather than when this list is
  /// empty.
  final List<CylinderTemplate> cylinderTemplates;

  static const int maxCylinderTemplates = kMaxCylinderTemplates;

  factory BlenderPreferences.defaults({required double cylinderWaterLiters}) =>
      BlenderPreferences(
        templates: seedTemplates,
        gasPrices: const [null, null, null],
        currencyCode: null,
        fillTempC: kReferenceTempC,
        settledTempC: kReferenceTempC,
        cylinderWaterLiters: cylinderWaterLiters,
        model: BlendGasModel.zFactor,
        billedFills: const [],
        billedTo: '',
        startPressureBar: 0.0,
        startMix: const GasMix(o2: 21),
        targetPressureBar: 200.0,
        targetMix: const GasMix(o2: 32),
        fillGas1: const GasMix(o2: 100),
        fillGas2: const GasMix(o2: 0, he: 100),
        fillGas3: const GasMix(o2: 21),
        cylinderTemplates: const [],
      );

  BlenderPreferences copyWith({
    List<MixTemplate>? templates,
    List<double?>? gasPrices,
    String? currencyCode,
    bool clearCurrencyCode = false,
    double? fillTempC,
    double? settledTempC,
    double? cylinderWaterLiters,
    BlendGasModel? model,
    List<BilledFill>? billedFills,
    String? billedTo,
    double? startPressureBar,
    GasMix? startMix,
    double? targetPressureBar,
    GasMix? targetMix,
    GasMix? fillGas1,
    GasMix? fillGas2,
    GasMix? fillGas3,
    List<CylinderTemplate>? cylinderTemplates,
  }) => BlenderPreferences(
    templates: (templates ?? this.templates).take(maxTemplates).toList(),
    gasPrices: gasPrices ?? this.gasPrices,
    // clearCurrencyCode is how it gets removed: null is meaningful here
    // (inherit the diver's default) and `??` cannot express it.
    currencyCode: clearCurrencyCode
        ? null
        : (currencyCode ?? this.currencyCode),
    fillTempC: fillTempC ?? this.fillTempC,
    settledTempC: settledTempC ?? this.settledTempC,
    cylinderWaterLiters: cylinderWaterLiters ?? this.cylinderWaterLiters,
    model: model ?? this.model,
    billedFills: (billedFills ?? this.billedFills)
        .take(maxBilledFills)
        .toList(),
    billedTo: billedTo ?? this.billedTo,
    startPressureBar: startPressureBar ?? this.startPressureBar,
    startMix: startMix ?? this.startMix,
    targetPressureBar: targetPressureBar ?? this.targetPressureBar,
    targetMix: targetMix ?? this.targetMix,
    fillGas1: fillGas1 ?? this.fillGas1,
    fillGas2: fillGas2 ?? this.fillGas2,
    fillGas3: fillGas3 ?? this.fillGas3,
    cylinderTemplates: (cylinderTemplates ?? this.cylinderTemplates)
        .take(maxCylinderTemplates)
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'templates': templates.map((t) => t.toJson()).toList(),
    'gasPrices': gasPrices,
    'currencyCode': currencyCode,
    'fillTempC': fillTempC,
    'settledTempC': settledTempC,
    'cylinderWaterLiters': cylinderWaterLiters,
    'model': model.name,
    'billedFills': billedFills.map((f) => f.toJson()).toList(),
    'billedTo': billedTo,
    'startPressureBar': startPressureBar,
    'startMix': _gasMixToJson(startMix),
    'targetPressureBar': targetPressureBar,
    'targetMix': _gasMixToJson(targetMix),
    'fillGas1': _gasMixToJson(fillGas1),
    'fillGas2': _gasMixToJson(fillGas2),
    'fillGas3': _gasMixToJson(fillGas3),
    'cylinderTemplates': cylinderTemplates.map((t) => t.toJson()).toList(),
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

    final rawFills = json['billedFills'];
    final fills = rawFills is List
        ? rawFills
              .map(BilledFill.fromJson)
              .whereType<BilledFill>()
              .take(maxBilledFills)
              .toList()
        : <BilledFill>[];

    final billedTo = json['billedTo'];

    final rawCylinderTemplates = json['cylinderTemplates'];
    final cylinderTemplates = rawCylinderTemplates is List
        ? rawCylinderTemplates
              .map(CylinderTemplate.fromJson)
              .whereType<CylinderTemplate>()
              .take(maxCylinderTemplates)
              .toList()
        : <CylinderTemplate>[];

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
      billedFills: fills,
      billedTo: billedTo is String ? billedTo : '',
      startPressureBar: _toDouble(json['startPressureBar']) ?? 0.0,
      startMix: _gasMixFromJson(json['startMix']) ?? const GasMix(o2: 21),
      targetPressureBar: _toDouble(json['targetPressureBar']) ?? 200.0,
      targetMix: _gasMixFromJson(json['targetMix']) ?? const GasMix(o2: 32),
      fillGas1: _gasMixFromJson(json['fillGas1']) ?? const GasMix(o2: 100),
      fillGas2:
          _gasMixFromJson(json['fillGas2']) ?? const GasMix(o2: 0, he: 100),
      fillGas3: _gasMixFromJson(json['fillGas3']) ?? const GasMix(o2: 21),
      cylinderTemplates: cylinderTemplates,
    );
  }
}

double? _toDouble(Object? value) {
  if (value is num) return value.toDouble();
  return null;
}

Map<String, double> _gasMixToJson(GasMix mix) => {'o2': mix.o2, 'he': mix.he};

/// Falls back per-field like every other read here, so a partly corrupt mix
/// still yields something rather than discarding the whole entry.
GasMix? _gasMixFromJson(Object? json) {
  if (json is! Map) return null;
  final o2 = _toDouble(json['o2']);
  final he = _toDouble(json['he']);
  if (o2 == null || he == null) return null;
  return GasMix(o2: o2, he: he);
}
