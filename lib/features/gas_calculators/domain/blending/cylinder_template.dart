/// A saved cylinder size for the blending bench: a name plus a water volume.
///
/// Deliberately lighter than `TankSpec`/`TankPresetEntity`: the blender's
/// cylinder-size vault only needs a label and litres to feed its dropdown, not
/// a working pressure or rated capacity (issue #1335). Follows the same shape
/// and JSON contract as [MixTemplate] in `blender_preferences.dart` on
/// purpose, so it costs no schema migration either.
class CylinderTemplate {
  const CylinderTemplate({required this.name, required this.liters});

  final String name;
  final double liters;

  bool get isValid => name.trim().isNotEmpty && liters > 0;

  Map<String, dynamic> toJson() => {'name': name, 'liters': liters};

  static CylinderTemplate? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final liters = _toDouble(json['liters']);
    if (name is! String || liters == null) return null;
    final t = CylinderTemplate(name: name, liters: liters);
    return t.isValid ? t : null;
  }

  @override
  bool operator ==(Object other) =>
      other is CylinderTemplate && other.name == name && other.liters == liters;

  @override
  int get hashCode => Object.hash(name, liters);

  @override
  String toString() => 'CylinderTemplate($name, $liters L)';

  /// The blending-bench sizes named in issue #1100 -- the 2 and 3 litre decant
  /// bottles, an AL80, and a steel twinset -- seeded on first use only.
  ///
  /// Formerly a separate, hard-coded list (`blenderTankChoices` in
  /// `tank_spec.dart`) offered alongside the diver's own templates in the
  /// cylinder dropdown. Issue #1335's follow-up asks for one editable list
  /// instead of two, so these now seed that list the same way
  /// [BlenderPreferences.seedTemplates] seeds the mix templates: a diver who
  /// deletes all of them keeps an empty list, because seeding keys on the
  /// absence of the whole blob rather than on an empty list.
  static const List<CylinderTemplate> seedTemplates = [
    CylinderTemplate(name: '2 L', liters: 2),
    CylinderTemplate(name: '3 L', liters: 3),
    CylinderTemplate(name: 'AL80', liters: 11.1),
    CylinderTemplate(name: 'Steel 12 L twinset', liters: 24),
  ];
}

/// Why a cylinder size cannot be saved as a template.
enum CylinderTemplateRejection {
  /// A blank name, or a size that is not greater than zero.
  invalid,

  /// The same name and size are already saved.
  duplicate,

  /// [maxCylinderTemplates] reached.
  limitReached,
}

/// Enough to keep the synced blob small without blocking a fill station that
/// genuinely stocks a few dozen bottle sizes.
const int kMaxCylinderTemplates = 50;

/// Why [candidate] cannot join [existing], or null when it can.
CylinderTemplateRejection? cylinderTemplateRejectionFor(
  List<CylinderTemplate> existing,
  CylinderTemplate candidate,
) {
  if (!candidate.isValid) return CylinderTemplateRejection.invalid;
  if (existing.contains(candidate)) return CylinderTemplateRejection.duplicate;
  if (existing.length >= kMaxCylinderTemplates) {
    return CylinderTemplateRejection.limitReached;
  }
  return null;
}

double? _toDouble(Object? value) {
  if (value is num) return value.toDouble();
  return null;
}
