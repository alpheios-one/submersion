// Creates a standalone Drift/SQLite database file containing one demo dive
// whose O2 cell millivolt curves sweep through all three agreement levels
// (issue #810): tight (green rug), drifting (yellow), and wide (red). Useful
// for eyeballing the traffic-light rug and the per-cell lines together
// without waiting on a real CCR log to drift that far.
//
// The output is a plain (unencrypted) copy of the app's own schema, not a
// file the Import wizard recognizes -- O2 cell millivolts only ever arrive
// via a live dive-computer download or this kind of direct database write,
// no import format carries them. Point a local dev build's database file at
// the output (or swap it in) to view it in the running app.
//
// Run: flutter test tool/create_o2_cell_demo_dive.dart
// Optional: OUTPUT=/some/path.db flutter test tool/create_o2_cell_demo_dive.dart
//
// Run through `flutter test`, not `dart run`: sqlite3's native/FFI codegen
// only compiles under the Flutter toolchain in this project (bare `dart run`
// crashes the kernel compiler's FFI transform), and every other place this
// database code runs standalone -- the repository tests -- already goes
// through `flutter test` for exactly that reason.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/core/services/database_service.dart';
import 'package:submersion/features/dive_log/data/repositories/dive_repository_impl.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart'
    as domain;

/// One profile sample per minute. Three straight thirds, each held level
/// long enough to read as a deliberate demo rather than a blip: tight
/// (spread 2 mV, under the 5 mV drifting threshold), drifting (8 mV, under
/// the 12 mV wide threshold), then wide (25 mV).
List<domain.DiveProfilePoint> _buildDemoProfile() {
  const totalMinutes = 40;
  final points = <domain.DiveProfilePoint>[];

  for (var minute = 0; minute <= totalMinutes; minute++) {
    final depth = _depthAt(minute, totalMinutes);
    final (mv1, mv2, mv3) = _cellsAt(minute, totalMinutes);
    points.add(
      domain.DiveProfilePoint(
        timestamp: minute * 60,
        depth: depth,
        temperature: 24.0 - depth * 0.15,
        ppO2: 1.2,
        o2SensorMv1: mv1,
        o2SensorMv2: mv2,
        o2SensorMv3: mv3,
      ),
    );
  }
  return points;
}

/// Descend to 35 m by minute 4, hold bottom to minute 30, a 3-minute safety
/// stop at 5 m from minute 35, surface by minute 40.
double _depthAt(int minute, int totalMinutes) {
  const bottomDepth = 35.0;
  const stopDepth = 5.0;
  if (minute <= 4) return bottomDepth * (minute / 4);
  if (minute <= 30) return bottomDepth;
  if (minute <= 34) {
    return bottomDepth - (bottomDepth - stopDepth) * ((minute - 30) / 4);
  }
  if (minute <= 37) return stopDepth;
  return stopDepth * (1 - (minute - 37) / (totalMinutes - 37));
}

(int, int, int) _cellsAt(int minute, int totalMinutes) {
  final third = totalMinutes / 3;
  if (minute < third) {
    // Tight: max - min = 2 mV.
    return (59, 61, 60);
  }
  if (minute < third * 2) {
    // Drifting: max - min = 8 mV.
    return (58, 66, 61);
  }
  // Wide: max - min = 25 mV.
  return (55, 80, 60);
}

Future<void> main() async {
  final outputPath =
      Platform.environment['OUTPUT'] ?? 'o2_cell_traffic_light_demo.db';
  final file = File(outputPath);
  if (file.existsSync()) file.deleteSync();

  final appDb = AppDatabase(NativeDatabase(file));
  // DatabaseService.initialize() resolves a platform app-data path via
  // path_provider and asserts SQLCipher is linked, neither of which is
  // available from a bare `dart run`. This is the only seam that points the
  // singleton at an arbitrary file instead.
  // ignore: invalid_use_of_visible_for_testing_member
  DatabaseService.instance.setTestDatabase(appDb);

  try {
    final repository = DiveRepository();
    await repository.createDive(
      domain.Dive(
        id: 'o2-cell-traffic-light-demo',
        diveNumber: 1,
        dateTime: DateTime.now(),
        maxDepth: 35.0,
        notes:
            'Demo dive for issue #810: the O2 Cell Spread rug runs tight '
            '(green) for the first third, drifting (yellow) for the '
            'second, and wide (red) for the last.',
        profile: _buildDemoProfile(),
      ),
    );
  } finally {
    await appDb.close();
  }

  // ignore: avoid_print
  print('Wrote demo dive to $outputPath');
}
