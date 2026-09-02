import 'package:flutter/foundation.dart';

import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/features/equipment/domain/entities/equipment_item.dart';

/// Filter state for the equipment list, shared by the phone, master-detail and
/// table layouts and edited through the filter panel.
///
/// Two independent axes:
///
/// - Status decides which provider the list reads: the default active-gear
///   view, the computed service-due list, or one [EquipmentStatus]. Those are
///   mutually exclusive because the list can only read one source.
/// - Type narrows the result client-side, so status and category compose with
///   AND semantics.
@immutable
class EquipmentFilterState {
  /// The status to show, or null for the default view. The default hides
  /// retired gear; the Retired status is the way to see it (#636).
  final EquipmentStatus? status;

  /// Show only gear with a service clock due. Mutually exclusive with
  /// [status].
  final bool serviceDueOnly;

  /// Narrow to a single gear category, or null for every category.
  final EquipmentType? type;

  const EquipmentFilterState({
    this.status,
    this.serviceDueOnly = false,
    this.type,
  }) : assert(
         !(serviceDueOnly && status != null),
         'The status axis is a single choice: service due or a status, never '
         'both -- the list reads one provider.',
       );

  /// Whether the panel is narrowing anything, i.e. whether the top-bar icon
  /// should carry its badge.
  bool get hasActiveFilters => hasStatusFilter || type != null;

  /// Whether the status axis is anything other than the default view.
  bool get hasStatusFilter => status != null || serviceDueOnly;

  /// Narrow [equipment] to the selected category.
  ///
  /// The status axis is applied upstream by provider selection, so this is the
  /// only filtering the list itself has to do.
  List<EquipmentItem> applyType(List<EquipmentItem> equipment) {
    final selected = type;
    if (selected == null) return equipment;
    return equipment.where((e) => e.type == selected).toList();
  }

  /// Copy with per-axis clearing. Clearing the status axis resets both of its
  /// values, since they are one choice to the diver.
  EquipmentFilterState copyWith({
    EquipmentStatus? status,
    bool? serviceDueOnly,
    EquipmentType? type,
    bool clearStatus = false,
    bool clearType = false,
  }) {
    return EquipmentFilterState(
      status: clearStatus ? null : (status ?? this.status),
      serviceDueOnly: clearStatus
          ? false
          : (serviceDueOnly ?? this.serviceDueOnly),
      type: clearType ? null : (type ?? this.type),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EquipmentFilterState &&
          other.status == status &&
          other.serviceDueOnly == serviceDueOnly &&
          other.type == type;

  @override
  int get hashCode => Object.hash(status, serviceDueOnly, type);

  @override
  String toString() =>
      'EquipmentFilterState(status: $status, serviceDueOnly: $serviceDueOnly, '
      'type: $type)';
}
