import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/data/repositories/sync_repository.dart';
import 'package:submersion/core/services/database_service.dart';
import 'package:submersion/core/services/sync/sync_data_serializer.dart';
import 'package:submersion/core/services/sync/sync_service.dart';

import '../../../helpers/test_database.dart';

/// [SyncService.deleteLeftoverBaseTempFiles] reaps `ssv1_` temp files from the
/// sync temp directory.
///
/// Under `flutter test` that directory is `Directory.systemTemp` -- machine
/// wide -- because `getTemporaryDirectory()` throws `MissingPluginException`
/// with no plugin host. Every concurrent test process therefore shares it, and
/// a base export in flight in one process sits right next to the sweep running
/// in another. The `ssv1_` prefix keeps the sweep off UNRELATED files, but the
/// files it is most likely to hit are another run's, which is why the age
/// guard, not the prefix, is what makes this safe.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    await setUpTestDatabase();
    tempDir = await Directory.systemTemp.createTemp('base_temp_sweep_');
  });

  tearDown(() async {
    DatabaseService.instance.resetForTesting();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  SyncService buildService() => SyncService(
    syncRepository: SyncRepository(),
    serializer: SyncDataSerializer(),
  );

  File write(String name, {Duration? age}) {
    final file = File('${tempDir.path}/$name')..writeAsStringSync('x');
    if (age != null) {
      file.setLastModifiedSync(DateTime.now().subtract(age));
    }
    return file;
  }

  test('spares a base export that is still being written', () async {
    // The regression: a sibling test process publishing a base has its
    // ssv1_base_*.json open in this same directory. Sweeping it kills that
    // publish, the sync returns non-success, and every assertion downstream
    // of "a successful sync" fails in a file that touched no sync code.
    final live = write('ssv1_base_device-a_1.abc123.json');

    await buildService().deleteLeftoverBaseTempFiles(
      tempDir: () async => tempDir,
    );

    expect(
      live.existsSync(),
      isTrue,
      reason: 'a file written seconds ago is in flight, not a leftover',
    );
  });

  test('deletes a leftover from an earlier run', () async {
    // The case the sweep exists for: a crash left an export behind. It is old
    // by definition, since a live one is being written right now.
    final stale = write(
      'ssv1_base_device-a_1.def456.json',
      age: const Duration(hours: 2),
    );

    await buildService().deleteLeftoverBaseTempFiles(
      tempDir: () async => tempDir,
    );

    expect(stale.existsSync(), isFalse);
  });

  test('never touches a file without the ssv1_ prefix, at any age', () async {
    final unrelated = write('someone_elses.json', age: const Duration(days: 3));

    await buildService().deleteLeftoverBaseTempFiles(
      tempDir: () async => tempDir,
    );

    expect(unrelated.existsSync(), isTrue);
  });

  test('sweeps the stale ones and spares the live ones in one pass', () async {
    final live = write('ssv1_adopt_live.base');
    final stale = write('ssv1_adopt_old.base', age: const Duration(days: 1));

    await buildService().deleteLeftoverBaseTempFiles(
      tempDir: () async => tempDir,
    );

    expect(live.existsSync(), isTrue);
    expect(stale.existsSync(), isFalse);
  });
}
