import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/media/data/resolvers/media_fetch_gate.dart';
import 'package:submersion/features/media/domain/value_objects/media_source_data.dart';

/// The store read path's concurrency cap and request coalescing (#1175).
void main() {
  MediaSourceData result(String path) => FileData(
    file: File(path),
    servedFrom: ServedFrom.storeNetwork,
    servedTier: ServedTier.thumbnail,
  );

  test('caps in-flight fetches at maxConcurrent', () async {
    final gate = MediaFetchGate(maxConcurrent: 2);
    final blockers = <Completer<MediaSourceData?>>[];
    var maxObserved = 0;

    final futures = [
      for (var i = 0; i < 6; i++)
        gate.run('key-$i', () {
          maxObserved = maxObserved > gate.runningCount
              ? maxObserved
              : gate.runningCount;
          final blocker = Completer<MediaSourceData?>();
          blockers.add(blocker);
          return blocker.future;
        }),
    ];

    await Future<void>.delayed(Duration.zero);
    expect(blockers, hasLength(2), reason: 'only two may be running');
    expect(gate.waitingCount, 4);
    expect(maxObserved, lessThanOrEqualTo(2));

    // Draining one admits exactly one waiter.
    blockers[0].complete(result('a'));
    await Future<void>.delayed(Duration.zero);
    expect(blockers, hasLength(3));

    // Drain by index: completing one admits a waiter, which appends to
    // `blockers` mid-loop.
    for (var i = 1; i < blockers.length; i++) {
      if (!blockers[i].isCompleted) blockers[i].complete(result('x'));
      await Future<void>.delayed(Duration.zero);
    }
    await Future.wait(futures);
    expect(gate.runningCount, 0);
  });

  test('duplicate keys share one fetch', () async {
    final gate = MediaFetchGate(maxConcurrent: 4);
    var calls = 0;
    final blocker = Completer<MediaSourceData?>();

    Future<MediaSourceData?> ask() => gate.run('same-hash#thumb', () {
      calls++;
      return blocker.future;
    });

    final first = ask();
    final second = ask();
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1, reason: 'the second caller must join the first fetch');

    blocker.complete(result('shared'));
    expect((await first as FileData).file.path, 'shared');
    expect((await second as FileData).file.path, 'shared');
  });

  test('a key is refetchable once its fetch finishes', () async {
    final gate = MediaFetchGate(maxConcurrent: 4);
    var calls = 0;

    Future<MediaSourceData?> ask() => gate.run('k', () async {
      calls++;
      return result('f');
    });

    await ask();
    await ask();
    expect(calls, 2, reason: 'coalescing is for in-flight requests only');
  });

  test('a failed fetch releases its slot and clears the key', () async {
    final gate = MediaFetchGate(maxConcurrent: 1);

    await expectLater(
      gate.run('k', () async => throw const FileSystemException('boom')),
      throwsA(isA<FileSystemException>()),
    );

    expect(gate.runningCount, 0);
    // A leaked in-flight entry would hand this caller the FAILED future
    // forever, so the tile could never recover.
    expect(await gate.run('k', () async => result('later')), isNotNull);
  });

  test('waiters are served in arrival order', () async {
    final gate = MediaFetchGate(maxConcurrent: 1);
    final started = <String>[];
    final blockers = <String, Completer<MediaSourceData?>>{};

    Future<MediaSourceData?> ask(String key) => gate.run(key, () {
      started.add(key);
      return (blockers[key] = Completer<MediaSourceData?>()).future;
    });

    final futures = [ask('a'), ask('b'), ask('c')];
    await Future<void>.delayed(Duration.zero);
    expect(started, ['a']);

    blockers['a']!.complete(result('a'));
    await Future<void>.delayed(Duration.zero);
    expect(started, ['a', 'b'], reason: 'FIFO: b queued before c');

    blockers['b']!.complete(result('b'));
    await Future<void>.delayed(Duration.zero);
    blockers['c']!.complete(result('c'));
    await Future.wait(futures);
  });
}
