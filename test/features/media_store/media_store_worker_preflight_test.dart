import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:submersion/core/database/local_cache_database.dart';
import 'package:submersion/core/models/log_entry.dart';
import 'package:submersion/core/services/logger_service.dart';
import 'package:submersion/core/services/media_store/media_object_store.dart';
import 'package:submersion/features/media/data/repositories/media_repository.dart';
import 'package:submersion/features/media/data/services/media_source_resolver_registry.dart';
import 'package:submersion/features/media_store/data/media_cache_store.dart';
import 'package:submersion/features/media_store/data/media_store_worker.dart';
import 'package:submersion/features/media_store/data/media_transfer_queue_repository.dart';
import 'package:submersion/features/media_store/data/media_upload_pipeline.dart';

import '../../helpers/in_memory_media_object_store.dart';
import '../../helpers/test_database.dart';

class _RecordingPipeline extends MediaUploadPipeline {
  _RecordingPipeline({
    required this.queueRef,
    required super.mediaRepository,
    required super.queue,
    required super.store,
    required super.registry,
    required super.cache,
  });

  final MediaTransferQueueRepository queueRef;
  final processed = <String>[];

  @override
  Future<UploadOutcome> process(MediaTransferQueueEntry entry) async {
    processed.add(entry.mediaId);
    await queueRef.markDone(entry.id);
    return UploadOutcome.uploaded;
  }
}

/// Polls [condition] until true or [within] elapses; the retry wakeup fires
/// on a real timer, so a fixed sleep would either flake under load or pad
/// every run.
Future<bool> _waitFor(
  bool Function() condition, {
  Duration within = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(within);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return condition();
}

void main() {
  late MediaRepository mediaRepository;
  late LocalCacheDatabase cacheDb;
  late Directory root;
  late MediaTransferQueueRepository queue;
  late _RecordingPipeline pipeline;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await setUpTestDatabase();
    mediaRepository = MediaRepository();
    cacheDb = LocalCacheDatabase(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('worker_preflight');
    queue = MediaTransferQueueRepository(database: cacheDb);
    pipeline = _RecordingPipeline(
      queueRef: queue,
      mediaRepository: mediaRepository,
      queue: queue,
      store: InMemoryMediaObjectStore(),
      registry: MediaSourceResolverRegistry({}),
      cache: MediaCacheStore(database: cacheDb, root: root),
    );
  });

  tearDown(() async {
    await cacheDb.close();
    if (root.existsSync()) await root.delete(recursive: true);
    await tearDownTestDatabase();
  });

  // Issue #942: preflight reads smv1/store.json from the bucket, so a network
  // blip throws. Every drain() call site is unawaited, so the throw escaped
  // into nothing and surfaced as "Uncaught zone error" - 25 of them in the
  // reporter's log. Preflight's contract is to suspend the drain; a failure to
  // determine the answer must suspend it too, not crash the zone.
  test(
    'a preflight that throws suspends the drain instead of escaping',
    () async {
      await queue.enqueueUpload(mediaId: 'm1');
      final worker = MediaStoreWorker(
        queue: queue,
        pipeline: pipeline,
        preflight: () async => throw const MediaStoreException(
          'get smv1/store.json failed: Could not reach S3 endpoint',
          kind: MediaStoreErrorKind.transient,
        ),
      );
      addTearDown(worker.dispose);

      await expectLater(worker.drain(), completes);
      expect(pipeline.processed, isEmpty);
    },
  );

  // Catching the throw is what removes the stack trace that used to reach the
  // zone handler, so this log line is now the only record of a preflight that
  // keeps failing. It must carry the cause through LoggerService's structured
  // error field (rendered as "| error: ..."), not interpolated into the text.
  test('the suspended drain logs the cause as a structured error', () async {
    await queue.enqueueUpload(mediaId: 'm1');
    final worker = MediaStoreWorker(
      queue: queue,
      pipeline: pipeline,
      preflight: () async => throw const MediaStoreException(
        'get smv1/store.json failed: Could not reach S3 endpoint',
        kind: MediaStoreErrorKind.transient,
      ),
    );
    addTearDown(worker.dispose);

    final entries = <LogEntry>[];
    final sub = LoggerService.logStream.listen(entries.add);
    addTearDown(sub.cancel);

    await worker.drain();

    expect(
      entries.map((e) => e.message),
      contains(
        allOf(
          contains('drain suspended'),
          contains('| error: MediaStoreException(transient)'),
          contains('smv1/store.json'),
        ),
      ),
    );
  });

  test(
    'a drain suspended by a throwing preflight can run again later',
    () async {
      await queue.enqueueUpload(mediaId: 'm1');
      var online = false;
      final worker = MediaStoreWorker(
        queue: queue,
        pipeline: pipeline,
        preflight: () async {
          if (!online) {
            throw const MediaStoreException(
              'get smv1/store.json failed: Could not reach S3 endpoint',
              kind: MediaStoreErrorKind.transient,
            );
          }
          return true;
        },
      );
      addTearDown(worker.dispose);

      await worker.drain();
      expect(pipeline.processed, isEmpty);

      online = true;
      await worker.drain();
      expect(pipeline.processed, ['m1']);
    },
  );

  // Issue #1356: a failed preflight left every due row untouched and armed
  // no wakeup (earliestPendingWakeup ignores due rows), so the queue sat at
  // "Waiting" until an external trigger re-ran the same failing check.
  test('a suspended drain arms a retry so the queue recovers without an '
      'external kick', () async {
    await queue.enqueueUpload(mediaId: 'm1');
    var verified = false;
    final worker = MediaStoreWorker(
      queue: queue,
      pipeline: pipeline,
      preflight: () async => verified,
      preflightRetryWindow: const Duration(milliseconds: 20),
    );
    addTearDown(worker.dispose);

    await worker.drain();
    expect(pipeline.processed, isEmpty);
    expect(worker.wakeupDelayForTesting, const Duration(milliseconds: 20));

    verified = true;
    expect(await _waitFor(() => pipeline.processed.contains('m1')), isTrue);
  });

  test('a suspended drain with nothing queued arms no retry', () async {
    final worker = MediaStoreWorker(
      queue: queue,
      pipeline: pipeline,
      preflight: () async => false,
    );
    addTearDown(worker.dispose);

    await worker.drain();
    expect(worker.wakeupDelayForTesting, isNull);
  });

  test('the suspension is observable and clears once the preflight '
      'passes', () async {
    await queue.enqueueUpload(mediaId: 'm1');
    var verified = false;
    final worker = MediaStoreWorker(
      queue: queue,
      pipeline: pipeline,
      preflight: () async => verified,
    );
    addTearDown(worker.dispose);
    final seen = <bool>[];
    final sub = worker.suspensionChanges.listen(seen.add);
    addTearDown(sub.cancel);

    expect(worker.isSuspended, isFalse);
    await worker.drain();
    expect(worker.isSuspended, isTrue);

    verified = true;
    await worker.drain();
    expect(worker.isSuspended, isFalse);
    expect(pipeline.processed, ['m1']);
    await Future<void>.delayed(Duration.zero);
    expect(seen, [true, false]);
  });

  test('a preflight that throws reads as suspended too', () async {
    await queue.enqueueUpload(mediaId: 'm1');
    final worker = MediaStoreWorker(
      queue: queue,
      pipeline: pipeline,
      preflight: () async => throw const MediaStoreException(
        'get smv1/store.json failed',
        kind: MediaStoreErrorKind.transient,
      ),
    );
    addTearDown(worker.dispose);

    await worker.drain();
    expect(worker.isSuspended, isTrue);
  });
}
