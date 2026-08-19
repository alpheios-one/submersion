import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

/// Localized labels for [ServiceType].
///
/// [ServiceType.displayName] stays hardcoded English on purpose: it is the
/// value written to spreadsheet exports, which are analysis targets rather
/// than UI surfaces. Only screens use this extension.
///
/// The switch is exhaustive rather than map-backed so that adding an enum
/// value is a compile error instead of a silent English fallback.
extension ServiceTypeL10n on ServiceType {
  String label(AppLocalizations l10n) => switch (this) {
    ServiceType.annual => l10n.equipment_serviceType_annual,
    ServiceType.repair => l10n.equipment_serviceType_repair,
    ServiceType.inspection => l10n.equipment_serviceType_inspection,
    ServiceType.overhaul => l10n.equipment_serviceType_overhaul,
    ServiceType.replacement => l10n.equipment_serviceType_replacement,
    ServiceType.cleaning => l10n.equipment_serviceType_cleaning,
    ServiceType.calibration => l10n.equipment_serviceType_calibration,
    ServiceType.warranty => l10n.equipment_serviceType_warranty,
    ServiceType.recall => l10n.equipment_serviceType_recall,
    ServiceType.other => l10n.equipment_serviceType_other,
  };
}
