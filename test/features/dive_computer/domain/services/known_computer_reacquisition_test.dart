import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/dive_computer/domain/entities/device_model.dart';
import 'package:submersion/features/dive_computer/domain/services/known_computer_reacquisition.dart';
import 'package:submersion/features/dive_log/domain/entities/dive_computer.dart';

DiveComputer _computer({
  String? manufacturer = 'Ratio',
  String? model = 'iX3M 2021 GPS Fancy',
}) {
  final now = DateTime(2026, 8, 31);
  return DiveComputer(
    id: 'dc-1',
    name: 'Ratio iX3M 2021 GPS Fancy',
    manufacturer: manufacturer,
    model: model,
    connectionType: 'bluetooth',
    bluetoothAddress: 'CBB1EC06-5D7C-4F20-7A6C-98BBB2F8F631',
    createdAt: now,
    updatedAt: now,
  );
}

DiscoveredDevice _device(
  String address, {
  String? manufacturer = 'Ratio',
  String? model = 'iX3M 2021 GPS Fancy',
  String name = 'RATIO-074691',
}) => DiscoveredDevice(
  id: address,
  name: name,
  connectionType: DeviceConnectionType.ble,
  address: address,
  recognizedModel: manufacturer == null || model == null
      ? null
      : DeviceModel(
          id: 'ratio_ix3m',
          manufacturer: manufacturer,
          model: model,
          connectionTypes: const [DeviceConnectionType.ble],
          dcModel: 96,
        ),
  discoveredAt: DateTime(2026, 8, 31),
);

void main() {
  // Issue #1423: a saved Ratio iX3M on iPhone stopped downloading once the
  // CoreBluetooth identifier stored as its address changed. The scan saw the
  // computer under its new identifier but only an exact address match was
  // accepted, so the download fell back to the stale one and never connected.
  group('sameModelFallbackDevice', () {
    const stale = 'CBB1EC06-5D7C-4F20-7A6C-98BBB2F8F631';
    const fresh = 'C4E774E2-7D1F-DB41-EBD3-69D345D782F3';

    test('returns the only device recognized as the saved model', () {
      final match = sameModelFallbackDevice(
        computer: _computer(),
        discovered: [_device(fresh)],
      );
      expect(match?.address, fresh);
    });

    test('returns null when nothing of that model advertised', () {
      expect(
        sameModelFallbackDevice(computer: _computer(), discovered: const []),
        isNull,
      );
      expect(
        sameModelFallbackDevice(
          computer: _computer(),
          discovered: [
            _device(fresh, manufacturer: 'Shearwater', model: 'Perdix 2'),
          ],
        ),
        isNull,
      );
    });

    test('returns null when two devices of the saved model advertised', () {
      // Two Ratios at the dive site: nothing says which one is the saved
      // computer, so the caller keeps the stored address.
      expect(
        sameModelFallbackDevice(
          computer: _computer(),
          discovered: [_device(fresh), _device(stale)],
        ),
        isNull,
      );
    });

    test('ignores devices libdivecomputer did not recognize', () {
      expect(
        sameModelFallbackDevice(
          computer: _computer(),
          discovered: [_device(fresh, manufacturer: null, model: null)],
        ),
        isNull,
      );
    });

    test('matches manufacturer and model ignoring case and surrounding '
        'whitespace, like findByHardwareIdentity', () {
      final match = sameModelFallbackDevice(
        computer: _computer(
          manufacturer: ' ratio ',
          model: 'IX3M 2021 GPS FANCY',
        ),
        discovered: [_device(fresh)],
      );
      expect(match?.address, fresh);
    });

    test('returns null when the saved computer has no model identity', () {
      expect(
        sameModelFallbackDevice(
          computer: _computer(manufacturer: null),
          discovered: [_device(fresh)],
        ),
        isNull,
      );
      expect(
        sameModelFallbackDevice(
          computer: _computer(model: ''),
          discovered: [_device(fresh)],
        ),
        isNull,
      );
    });
  });
}
