import 'package:equatable/equatable.dart';

/// Domain entity for a transmitter registry entry (issue #1365): a
/// deterministic mapping from a dive computer's air-integration channel
/// index to a cylinder role and, optionally, a tank preset / equipment link.
///
/// libdivecomputer never exposes a transmitter serial number through the
/// portable API -- only the channel index -- so (diveComputerId,
/// channelIndex) stands in for physical transmitter identity, since that
/// pairing is persistent on the device. [transmitterSerial] is reserved for
/// a future extension that reads paired serials out of the Shearwater log
/// opening block; it plays no role in import matching today.
class TransmitterEntity extends Equatable {
  final String id;
  final String diveComputerId;
  final int channelIndex;
  final String? label;
  final String? transmitterSerial;
  final String? equipmentId;

  /// A [TankRole] name (e.g. 'backGas', 'diluent', 'oxygenSupply'), or null
  /// to leave role inference to the existing heuristic.
  final String? tankRole;

  /// A tank preset id (custom or built-in) whose size/material/working
  /// pressure is stamped on the cylinder this channel produces.
  final String? tankPresetId;

  final DateTime createdAt;
  final DateTime updatedAt;

  const TransmitterEntity({
    required this.id,
    required this.diveComputerId,
    required this.channelIndex,
    this.label,
    this.transmitterSerial,
    this.equipmentId,
    this.tankRole,
    this.tankPresetId,
    required this.createdAt,
    required this.updatedAt,
  });

  TransmitterEntity copyWith({
    String? id,
    String? diveComputerId,
    int? channelIndex,
    String? label,
    bool clearLabel = false,
    String? transmitterSerial,
    bool clearTransmitterSerial = false,
    String? equipmentId,
    bool clearEquipmentId = false,
    String? tankRole,
    bool clearTankRole = false,
    String? tankPresetId,
    bool clearTankPresetId = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return TransmitterEntity(
      id: id ?? this.id,
      diveComputerId: diveComputerId ?? this.diveComputerId,
      channelIndex: channelIndex ?? this.channelIndex,
      label: clearLabel ? null : (label ?? this.label),
      transmitterSerial: clearTransmitterSerial
          ? null
          : (transmitterSerial ?? this.transmitterSerial),
      equipmentId: clearEquipmentId ? null : (equipmentId ?? this.equipmentId),
      tankRole: clearTankRole ? null : (tankRole ?? this.tankRole),
      tankPresetId: clearTankPresetId
          ? null
          : (tankPresetId ?? this.tankPresetId),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  List<Object?> get props => [
    id,
    diveComputerId,
    channelIndex,
    label,
    transmitterSerial,
    equipmentId,
    tankRole,
    tankPresetId,
    createdAt,
    updatedAt,
  ];
}
