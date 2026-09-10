import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/services/sync/changeset_log/byte_progress_stream.dart';

void main() {
  Future<(List<int> passed, List<int> reports)> run(
    List<List<int>> chunks,
    int interval,
  ) async {
    final reports = <int>[];
    final passed = <int>[];
    await for (final c in withByteProgress(
      Stream.fromIterable(chunks),
      onProgress: reports.add,
      interval: interval,
    )) {
      passed.addAll(c);
    }
    return (passed, reports);
  }

  test('passes every byte through unchanged', () async {
    final (passed, _) = await run([
      [1, 2, 3],
      [4],
      [5, 6],
    ], 100);
    expect(passed, [1, 2, 3, 4, 5, 6]);
  });

  test('reports once per interval crossed and once more at the end', () async {
    final (_, reports) = await run([
      List.filled(3, 0),
      List.filled(3, 0), // crosses 4 at 6
      List.filled(1, 0),
      List.filled(5, 0), // crosses 10 at 12
      List.filled(1, 0),
    ], 4);
    expect(reports, [6, 12, 13]);
  });

  test('a stream shorter than one interval still reports its total', () async {
    final (_, reports) = await run([
      [1, 2],
    ], 1 << 20);
    expect(reports, [2]);
  });

  test('an empty stream reports zero', () async {
    final (_, reports) = await run([], 8);
    expect(reports, [0]);
  });
}
