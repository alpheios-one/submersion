import 'package:submersion/features/gas_calculators/domain/blending/billed_fill.dart';
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
    this.billedDate,
    this.archivedInvoices = const [],
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

  /// When the running bill started. Null means "not set yet", which the
  /// invoice card reads as today: the date is editable from the moment a
  /// bill is open, not only once it is paid.
  final DateTime? billedDate;

  /// Bills already paid and archived, oldest first. See [ArchivedInvoice].
  final List<ArchivedInvoice> archivedInvoices;

  /// Lives beside [BilledFill] itself; re-exposed here because the JSON read
  /// path enforces it.
  static const int maxBilledFills = kMaxBilledFills;

  /// Lives beside [ArchivedInvoice] itself; re-exposed here for the same
  /// reason as [maxBilledFills].
  static const int maxArchivedInvoices = kMaxArchivedInvoices;

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
        billedDate: null,
        archivedInvoices: const [],
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
    DateTime? billedDate,
    List<ArchivedInvoice>? archivedInvoices,
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
    billedDate: billedDate ?? this.billedDate,
    archivedInvoices: (archivedInvoices ?? this.archivedInvoices)
        .take(maxArchivedInvoices)
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
    if (billedDate != null) 'billedDate': billedDate!.toIso8601String(),
    'archivedInvoices': archivedInvoices.map((a) => a.toJson()).toList(),
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

    final billedDateRaw = json['billedDate'];
    final billedDate = billedDateRaw is String
        ? DateTime.tryParse(billedDateRaw)
        : null;

    final rawArchived = json['archivedInvoices'];
    final archivedInvoices = rawArchived is List
        ? rawArchived
              .map(ArchivedInvoice.fromJson)
              .whereType<ArchivedInvoice>()
              .take(maxArchivedInvoices)
              .toList()
        : <ArchivedInvoice>[];

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
      billedDate: billedDate,
      archivedInvoices: archivedInvoices,
    );
  }
}

double? _toDouble(Object? value) {
  if (value is num) return value.toDouble();
  return null;
}
