import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/core/constants/tank_presets.dart';
import 'package:submersion/features/dive_computer/data/services/transmitter_registry_resolver.dart';
import 'package:submersion/features/dive_computer/domain/entities/transmitter_entity.dart';
import 'package:submersion/features/dive_log/data/repositories/dive_computer_repository_impl.dart';
import 'package:submersion/features/tank_presets/domain/entities/tank_preset_entity.dart';

/// The transmitter registry maps a dive computer's air-integration channel
/// index to a cylinder role/template (issue #1365), so a download can assign
/// size, gas and role deterministically instead of relying on the
/// orphan-to-tank heuristic and the global default tank preset alone.
void main() {
  final al80 = TankPresetEntity.fromBuiltIn(TankPresets.al80);
  final now = DateTime(2026, 1, 1);

  TransmitterEntity entry({
    required int channelIndex,
    String? tankRole,
    String? tankPresetId,
    String? equipmentId,
  }) {
    return TransmitterEntity(
      id: 't-$channelIndex',
      diveComputerId: 'dc-1',
      channelIndex: channelIndex,
      tankRole: tankRole,
      tankPresetId: tankPresetId,
      equipmentId: equipmentId,
      createdAt: now,
      updatedAt: now,
    );
  }

  test('a tank on an unmapped channel is returned unchanged, only stamped '
      'as dc_import', () {
    const tank = TankData(index: 0, o2Percent: 21.0, startPressure: 200);

    final result = applyTransmitterRegistryToTanks([
      tank,
    ], TransmitterRegistrySnapshot.empty);

    expect(result, hasLength(1));
    expect(result.first.volumeLiters, isNull);
    expect(result.first.role, isNull);
    expect(result.first.source, 'dc_import');
    expect(result.first.sensorRef, isNull);
  });

  test('a registry entry with a tank preset stamps size, material and '
      'role, and a sensorRef for idempotent re-imports', () {
    const tank = TankData(index: 2, o2Percent: 100.0);
    final registry = TransmitterRegistrySnapshot(
      byChannel: {
        2: entry(
          channelIndex: 2,
          tankRole: TankRole.oxygenSupply.name,
          tankPresetId: al80.id,
        ),
      },
      presetsById: {al80.id: al80},
    );

    final result = applyTransmitterRegistryToTanks([tank], registry);

    expect(result.first.volumeLiters, al80.volumeLiters);
    expect(result.first.workingPressure, al80.workingPressureBar);
    expect(result.first.material, TankMaterial.aluminum.name);
    expect(result.first.presetName, al80.name);
    expect(result.first.role, TankRole.oxygenSupply.name);
    expect(result.first.source, 'dc_import');
    expect(result.first.sensorRef, 'channel:2');
  });

  test('a registry entry without a tank preset only assigns the role', () {
    const tank = TankData(index: 1, o2Percent: 32.0, volumeLiters: 11.1);
    final registry = TransmitterRegistrySnapshot(
      byChannel: {1: entry(channelIndex: 1, tankRole: TankRole.diluent.name)},
    );

    final result = applyTransmitterRegistryToTanks([tank], registry);

    expect(result.first.role, TankRole.diluent.name);
    // The computer's own volume is not clobbered when no template applies.
    expect(result.first.volumeLiters, 11.1);
    expect(result.first.sensorRef, 'channel:1');
  });

  test('a registry entry carries its equipment link onto the tank', () {
    const tank = TankData(index: 0, o2Percent: 21.0);
    final registry = TransmitterRegistrySnapshot(
      byChannel: {0: entry(channelIndex: 0, equipmentId: 'equip-1')},
    );

    final result = applyTransmitterRegistryToTanks([tank], registry);

    expect(result.first.equipmentId, 'equip-1');
  });

  test('only the matched channel is affected; other channels pass through '
      'to the existing heuristic/default-preset fallback', () {
    const tanks = [
      TankData(index: 0, o2Percent: 21.0),
      TankData(index: 1, o2Percent: 100.0),
    ];
    final registry = TransmitterRegistrySnapshot(
      byChannel: {
        1: entry(channelIndex: 1, tankRole: TankRole.oxygenSupply.name),
      },
    );

    final result = applyTransmitterRegistryToTanks(tanks, registry);

    expect(result[0].role, isNull);
    expect(result[0].sensorRef, isNull);
    expect(result[1].role, TankRole.oxygenSupply.name);
    expect(result[1].sensorRef, 'channel:1');
  });

  test('does not mutate the input list', () {
    const tank = TankData(index: 0, o2Percent: 21.0);
    final input = [tank];

    applyTransmitterRegistryToTanks(
      input,
      TransmitterRegistrySnapshot(
        byChannel: {0: entry(channelIndex: 0, tankRole: TankRole.stage.name)},
      ),
    );

    expect(input.first.role, isNull);
  });
}
