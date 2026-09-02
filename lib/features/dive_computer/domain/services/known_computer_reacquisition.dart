import 'package:submersion/features/dive_log/domain/entities/dive_computer.dart';
import 'package:submersion/features/dive_computer/domain/entities/device_model.dart';

/// The one discovered device that can stand in for [computer] when nothing
/// advertised its stored address.
///
/// The address saved for a Bluetooth computer is a host-local identifier, not
/// a property of the hardware: Android and Windows store the MAC, and iOS and
/// macOS store the CoreBluetooth identifier that the OS mints per address.
/// Computers that rotate their Bluetooth address (the Ratio iX3M in issue
/// #1423) therefore come back under a new identifier, and a scan that insists
/// on the stored one never finds them even while they are advertising.
///
/// Returns the single device libdivecomputer recognized as the saved
/// computer's manufacturer and model (compared ignoring case and surrounding
/// whitespace, as the repository's hardware-identity lookup does), or null
/// when there is none or more than one. With two candidates nothing distinguishes the saved computer from a
/// buddy's, so the caller keeps the stored address. The serial number reported
/// by the download later confirms (or rejects) the match before the stored
/// address is rewritten.
DiscoveredDevice? sameModelFallbackDevice({
  required DiveComputer computer,
  required Iterable<DiscoveredDevice> discovered,
}) {
  final manufacturer = _normalize(computer.manufacturer);
  final model = _normalize(computer.model);
  if (manufacturer.isEmpty || model.isEmpty) return null;

  final candidates = discovered
      .where(
        (device) =>
            _normalize(device.manufacturer) == manufacturer &&
            _normalize(device.model) == model,
      )
      .toList();
  return candidates.length == 1 ? candidates.single : null;
}

String _normalize(String? value) => (value ?? '').trim().toLowerCase();
