import 'package:submersion/features/universal_import/data/services/macdive_raw_types.dart';
import 'package:submersion/features/universal_import/data/services/macdive_samples_decoder.dart';
import 'package:submersion/features/universal_import/data/services/macdive_xml_models.dart'
    show MacDiveUnitSystem;

/// Works out which unit system a MacDive Core Data store was written under.
///
/// MacDive records the preference in `ZMETADATA.ZALL` where
/// `ZIDENTIFIER = 'SystemOfUnits'`, but real libraries are routinely missing
/// that row - the 540-dive reference database has a `ZMETADATA` table whose
/// only row carries a UUID and a null value. Treating that as "unknown" and
/// passing values through unconverted is what made imported tank pressures
/// nonsensical (#912): 3118 psi arrived as 3118 bar.
///
/// The magnitudes involved are far apart, so the data itself is a reliable
/// witness. Working pressures are ~200-300 bar or ~2400-3500 psi - more than
/// an order of magnitude apart, with nothing plausible in between.
///
/// The witnesses are tried cheapest first. The cylinder columns are already
/// in memory; the sample pressures inside `ZSAMPLES` cost a decrypt per dive,
/// so they are the last resort - reached only by a library that records no
/// cylinders at all, which is exactly the library that used to have no
/// witness whatsoever.
class MacDiveUnitInference {
  const MacDiveUnitInference._();

  /// Above this, a pressure can only be psi: no cylinder is filled to 600 bar.
  static const _pressureBarCeiling = 600.0;

  /// Above this, a cylinder "size" can only be cubic feet: no single cylinder
  /// holds 40 litres of water.
  static const _tankSizeLitreCeiling = 40.0;

  /// How many dives carrying a `ZSAMPLES` blob the last-resort scan will
  /// decrypt before giving up.
  ///
  /// Decoding one costs a TEA pass over the dive's whole profile, and a
  /// library that reaches this tier records no cylinders at all: if this many
  /// of its dives carry no pressure reading, the next 500 almost certainly do
  /// not either. The bound is what makes [MacDiveUnitSystem.unknown] still
  /// reachable with sample pressures present further down the library, so
  /// callers must keep treating unknown as "do not convert" rather than
  /// assuming this tier saw everything.
  static const sampleScanDiveLimit = 25;

  /// Resolves the display unit for [logbook], preferring MacDive's own
  /// declaration and falling back to inference from the data.
  static MacDiveUnitSystem resolve(MacDiveRawLogbook logbook) {
    final declared = MacDiveUnitSystem.fromXml(logbook.unitsPreference);
    if (declared != MacDiveUnitSystem.unknown) return declared;
    return infer(logbook);
  }

  /// Infers the display unit purely from stored magnitudes. Returns
  /// [MacDiveUnitSystem.unknown] when the logbook carries no usable signal,
  /// so callers keep the conservative passthrough behaviour.
  static MacDiveUnitSystem infer(MacDiveRawLogbook logbook) {
    // Strongest signal: cylinder pressures.
    final pressures = <double>[
      for (final t in logbook.tanksByPk.values)
        if (t.workingPressure != null && t.workingPressure! > 0)
          t.workingPressure!,
      for (final tg in logbook.tankAndGases) ...[
        if (tg.airStart != null && tg.airStart! > 0) tg.airStart!,
        if (tg.airEnd != null && tg.airEnd! > 0) tg.airEnd!,
      ],
    ];
    if (pressures.isNotEmpty) {
      final max = pressures.reduce((a, b) => a > b ? a : b);
      return max > _pressureBarCeiling
          ? MacDiveUnitSystem.imperial
          : MacDiveUnitSystem.metric;
    }

    // Next best: cylinder size, cubic feet vs litres.
    final sizes = <double>[
      for (final t in logbook.tanksByPk.values)
        if (t.size != null && t.size! > 0) t.size!,
    ];
    if (sizes.isNotEmpty) {
      final max = sizes.reduce((a, b) => a > b ? a : b);
      return max > _tankSizeLitreCeiling
          ? MacDiveUnitSystem.imperial
          : MacDiveUnitSystem.metric;
    }

    // Last resort: the pressures MacDive stored inside its own sample blobs.
    // The same physical quantity as a cylinder fill, separated by the same
    // ceiling, but it has to be decrypted, so it runs only once the free
    // signals have come up empty.
    final samplePressure = _maxSamplePressure(logbook);
    if (samplePressure != null) {
      return samplePressure > _pressureBarCeiling
          ? MacDiveUnitSystem.imperial
          : MacDiveUnitSystem.metric;
    }

    // Nothing to go on. Passthrough is safer than a coin flip.
    return MacDiveUnitSystem.unknown;
  }

  /// The largest positive pressure in the first [sampleScanDiveLimit] dives
  /// that carry a `ZSAMPLES` blob, or null when none of them holds one.
  ///
  /// Returns as soon as a reading can only be psi: no later reading can move
  /// the answer, and stopping saves decrypting the rest of the library.
  ///
  /// A blob the decoder rejects does not end the scan, since one unreadable
  /// dive says nothing about the units of the others, but it does count
  /// against [sampleScanDiveLimit]. The limit bounds decryption work, not
  /// useful readings: any blob that gets past the cheap header checks is
  /// rejected only after its body has been decrypted, so an unreadable dive
  /// costs what a readable one costs. Counting only successful decodes would
  /// leave a library of unreadable blobs with no bound at all.
  static double? _maxSamplePressure(MacDiveRawLogbook logbook) {
    double? highest;
    var scanned = 0;
    for (final dive in logbook.dives) {
      final blob = dive.samplesBlob;
      if (blob == null || blob.isEmpty) continue;
      if (scanned >= sampleScanDiveLimit) break;
      scanned++;
      final samples = MacDiveSamplesDecoder.decode(blob);
      if (samples == null) continue;
      for (final s in samples) {
        for (final pressure in [s.pressure, s.pressure2]) {
          if (pressure == null || pressure <= 0) continue;
          if (highest == null || pressure > highest) highest = pressure;
        }
      }
      if (highest != null && highest > _pressureBarCeiling) return highest;
    }
    return highest;
  }
}
