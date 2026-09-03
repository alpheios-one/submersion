import 'package:submersion/core/database/imported_computer_identity.dart';
import 'package:submersion/features/dive_log/domain/entities/dive_computer.dart';

/// Pure rules for reconciling dive computer records that describe one
/// physical device (issue #645).
///
/// A Bluetooth identifier is local to the host that discovered the computer,
/// so the same Petrel can be saved once per Mac, iPhone and iPad. The serial
/// number, with manufacturer and model, is the stable identity these rules
/// compare on. Everything here is side-effect free so the repository, the
/// merge sheet and the duplicate banner share one definition of "duplicate".

/// Other records in [all] that look like the same physical computer as
/// [target]: a shared non-blank serial number, a compatible manufacturer and
/// model, and the same owner.
///
/// Manufacturer and model are compatible when they agree after normalisation
/// or when either side is blank; a file import can register a serial without
/// a model, and that record is still the same device.
List<DiveComputer> duplicateCandidatesFor(
  DiveComputer target,
  Iterable<DiveComputer> all,
) {
  final serial = normalizeComputerIdentityPart(target.serialNumber);
  if (serial.isEmpty) return const [];
  final diver = normalizeComputerIdentityPart(target.diverId);
  return [
    for (final candidate in all)
      if (candidate.id != target.id &&
          normalizeComputerIdentityPart(candidate.serialNumber) == serial &&
          normalizeComputerIdentityPart(candidate.diverId) == diver &&
          _compatible(target.manufacturer, candidate.manufacturer) &&
          _compatible(target.model, candidate.model))
        candidate,
  ];
}

bool _compatible(String? a, String? b) {
  final left = normalizeComputerIdentityPart(a);
  final right = normalizeComputerIdentityPart(b);
  return left.isEmpty || right.isEmpty || left == right;
}

/// Whether [records] carry two different non-blank serial numbers, which
/// means the user is about to merge what are probably different devices.
bool serialNumbersConflict(Iterable<DiveComputer> records) {
  final serials = {
    for (final record in records)
      if (normalizeComputerIdentityPart(record.serialNumber).isNotEmpty)
        normalizeComputerIdentityPart(record.serialNumber),
  };
  return serials.length > 1;
}

/// The record a merge should keep unless the user says otherwise: the
/// favorite, else the one with the most dives, else the most recently
/// downloaded, else the first.
DiveComputer defaultSurvivor(List<DiveComputer> records) {
  assert(records.isNotEmpty, 'defaultSurvivor needs at least one record');
  var best = records.first;
  for (final candidate in records.skip(1)) {
    if (_ranksAbove(candidate, best)) best = candidate;
  }
  return best;
}

bool _ranksAbove(DiveComputer candidate, DiveComputer incumbent) {
  if (candidate.isFavorite != incumbent.isFavorite) return candidate.isFavorite;
  if (candidate.diveCount != incumbent.diveCount) {
    return candidate.diveCount > incumbent.diveCount;
  }
  return _isLater(candidate.lastDownload, incumbent.lastDownload);
}

bool _isLater(DateTime? a, DateTime? b) {
  if (a == null) return false;
  if (b == null) return true;
  return a.isAfter(b);
}

/// The surviving record after [duplicates] fold into [survivor].
///
/// Identity fields (id, name, owner) stay the survivor's. Blank descriptive
/// fields are filled from the first duplicate that has them. Dive counts add
/// up, favorite status is kept if any record had it, the newest download wins,
/// and distinct notes are appended.
///
/// `lastDiveFingerprint` is picked by download recency rather than by list
/// order: it is the cursor the next incremental download resumes from, so it
/// has to come from the most recent download that actually recorded one. A
/// record can hold a `lastDownload` with no fingerprint (the two are written
/// separately), and taking the survivor's stale cursor in that case would
/// resume from the wrong dive.
DiveComputer mergedDiveComputer(
  DiveComputer survivor,
  List<DiveComputer> duplicates,
) {
  final records = [survivor, ...duplicates];
  final newest = records.reduce(
    (best, candidate) =>
        _isLater(candidate.lastDownload, best.lastDownload) ? candidate : best,
  );
  final fingerprint = _newestFingerprint(records);

  return survivor.copyWith(
    manufacturer: _firstNonBlank([
      survivor.manufacturer,
      ...duplicates.map((d) => d.manufacturer),
    ]),
    model: _firstNonBlank([survivor.model, ...duplicates.map((d) => d.model)]),
    serialNumber: _firstNonBlank([
      survivor.serialNumber,
      ...duplicates.map((d) => d.serialNumber),
    ]),
    firmwareVersion: _firstNonBlank([
      survivor.firmwareVersion,
      ...duplicates.map((d) => d.firmwareVersion),
    ]),
    connectionType: _firstNonBlank([
      survivor.connectionType,
      ...duplicates.map((d) => d.connectionType),
    ]),
    bluetoothAddress: _firstNonBlank([
      survivor.bluetoothAddress,
      ...duplicates.map((d) => d.bluetoothAddress),
    ]),
    equipmentId: _firstNonBlank([
      survivor.equipmentId,
      ...duplicates.map((d) => d.equipmentId),
    ]),
    lastDownload: newest.lastDownload,
    lastDiveFingerprint: fingerprint,
    diveCount: duplicates.fold<int>(
      survivor.diveCount,
      (sum, d) => sum + d.diveCount,
    ),
    isFavorite: survivor.isFavorite || duplicates.any((d) => d.isFavorite),
    notes: _mergedNotes(survivor.notes, duplicates.map((d) => d.notes)),
  );
}

/// The `lastDiveFingerprint` of the most recently downloaded record that has
/// one. Records without a fingerprint are skipped rather than shadowing an
/// older record's cursor, and ties keep the earliest entry, which is the
/// survivor.
String? _newestFingerprint(List<DiveComputer> records) {
  DiveComputer? best;
  for (final record in records) {
    final fingerprint = record.lastDiveFingerprint;
    if (fingerprint == null || fingerprint.trim().isEmpty) continue;
    if (best == null || _isLater(record.lastDownload, best.lastDownload)) {
      best = record;
    }
  }
  return best?.lastDiveFingerprint;
}

String? _firstNonBlank(Iterable<String?> values) {
  for (final value in values) {
    if (value != null && value.trim().isNotEmpty) return value;
  }
  return null;
}

String _mergedNotes(String survivorNotes, Iterable<String> duplicateNotes) {
  final parts = <String>[];
  final seen = <String>{};
  for (final notes in [survivorNotes, ...duplicateNotes]) {
    final trimmed = notes.trim();
    if (trimmed.isEmpty || !seen.add(trimmed)) continue;
    parts.add(trimmed);
  }
  return parts.join('\n\n');
}
