import 'package:submersion/features/dive_computer/domain/entities/transmitter_entity.dart';
import 'package:submersion/features/dive_log/data/repositories/dive_computer_repository_impl.dart';
import 'package:submersion/features/tank_presets/domain/entities/tank_preset_entity.dart';

/// A dive computer's transmitter registry, pre-resolved for one import so
/// the pure resolver below never has to hit the database.
class TransmitterRegistrySnapshot {
  /// Registry entries keyed by channel index.
  final Map<int, TransmitterEntity> byChannel;

  /// Tank presets referenced by any entry in [byChannel], keyed by id.
  final Map<String, TankPresetEntity> presetsById;

  const TransmitterRegistrySnapshot({
    this.byChannel = const {},
    this.presetsById = const {},
  });

  static const empty = TransmitterRegistrySnapshot();
}

/// Apply the transmitter registry to a download's parsed [tanks], per the
/// assignment order from issue #1365:
///
/// 1. A registry entry exists for (computer, channel) -> its role and, when
///    it references a tank preset, that preset's size/material/working
///    pressure are stamped onto the cylinder, and its pressure profile stays
///    linked by channel index as before.
/// 2. No entry -> the tank is returned unchanged (the existing
///    orphan-to-tank heuristic and default-tank-preset fallback still apply
///    downstream, in `downloaded_tank_defaults.dart`).
///
/// Every tank is stamped `source: 'dc_import'` regardless of whether a
/// registry entry matched, and registry-assigned tanks additionally get a
/// `sensorRef` of `"channel:<index>"` so re-imports of the same dive stay
/// idempotent. Returns a new list; never mutates [tanks].
List<TankData> applyTransmitterRegistryToTanks(
  List<TankData> tanks,
  TransmitterRegistrySnapshot registry,
) {
  return tanks.map((tank) {
    final entry = registry.byChannel[tank.index];
    if (entry == null) {
      return TankData(
        index: tank.index,
        o2Percent: tank.o2Percent,
        hePercent: tank.hePercent,
        startPressure: tank.startPressure,
        endPressure: tank.endPressure,
        volumeLiters: tank.volumeLiters,
        workingPressure: tank.workingPressure,
        material: tank.material,
        presetName: tank.presetName,
        role: tank.role,
        source: 'dc_import',
        sensorRef: tank.sensorRef,
        equipmentId: tank.equipmentId,
      );
    }

    final preset = entry.tankPresetId == null
        ? null
        : registry.presetsById[entry.tankPresetId];

    return TankData(
      index: tank.index,
      o2Percent: tank.o2Percent,
      hePercent: tank.hePercent,
      startPressure: tank.startPressure,
      endPressure: tank.endPressure,
      volumeLiters: preset?.volumeLiters ?? tank.volumeLiters,
      workingPressure: preset?.workingPressureBar ?? tank.workingPressure,
      material: preset?.material.name ?? tank.material,
      presetName: preset?.name ?? tank.presetName,
      role: entry.tankRole ?? tank.role,
      source: 'dc_import',
      sensorRef: 'channel:${tank.index}',
      equipmentId: entry.equipmentId ?? tank.equipmentId,
    );
  }).toList();
}
