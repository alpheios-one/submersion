import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:submersion/core/services/windows_app_data_migration.dart';

/// These tests exercise the pure directory-move core on the host filesystem so
/// the behaviour is covered on the POSIX CI matrix. The Windows-only decision
/// of WHICH roots to migrate lives in migrateWindowsAppDataDirectories and is
/// guarded by Platform.isWindows.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('win_appdata_migration_test_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String legacyPath() => p.join(root.path, 'Eric Griffin', 'submersion');
  String targetPath() => p.join(root.path, 'Submersion', 'submersion');

  Future<AppDataMigrationReport> migrate({
    Future<Directory> Function(Directory, String)? rename,
  }) {
    return migrateCompanyDirectory(
      rootPath: root.path,
      legacyCompany: 'Eric Griffin',
      company: 'Submersion',
      product: 'submersion',
      rename: rename,
    );
  }

  void seedLegacy() {
    Directory(p.join(legacyPath(), 'logs')).createSync(recursive: true);
    File(p.join(legacyPath(), 'shared_preferences.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"unit_system":"metric"}');
    File(
      p.join(legacyPath(), 'logs', 'submersion-debug.log'),
    ).writeAsStringSync('line one');
  }

  group('migrateCompanyDirectory', () {
    test(
      'moves the legacy company directory onto the new company name',
      () async {
        seedLegacy();

        final report = await migrate();

        expect(report.outcome, AppDataMigrationOutcome.moved);
        expect(Directory(targetPath()).existsSync(), isTrue);
        expect(Directory(legacyPath()).existsSync(), isFalse);
      },
    );

    test('carries nested file contents across the move', () async {
      seedLegacy();

      await migrate();

      expect(
        File(
          p.join(targetPath(), 'shared_preferences.json'),
        ).readAsStringSync(),
        '{"unit_system":"metric"}',
      );
      expect(
        File(
          p.join(targetPath(), 'logs', 'submersion-debug.log'),
        ).readAsStringSync(),
        'line one',
      );
    });

    test('does nothing when there is no legacy directory', () async {
      final report = await migrate();

      expect(report.outcome, AppDataMigrationOutcome.noLegacyData);
      expect(Directory(targetPath()).existsSync(), isFalse);
    });

    test(
      'leaves both directories untouched when the target already has data',
      () async {
        seedLegacy();
        File(p.join(targetPath(), 'shared_preferences.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync('{"unit_system":"imperial"}');

        final report = await migrate();

        expect(report.outcome, AppDataMigrationOutcome.targetAlreadyPopulated);
        expect(Directory(legacyPath()).existsSync(), isTrue);
        expect(
          File(
            p.join(targetPath(), 'shared_preferences.json'),
          ).readAsStringSync(),
          '{"unit_system":"imperial"}',
        );
      },
    );

    test('replaces an empty target directory rather than refusing', () async {
      seedLegacy();
      Directory(targetPath()).createSync(recursive: true);

      final report = await migrate();

      expect(report.outcome, AppDataMigrationOutcome.moved);
      expect(
        File(
          p.join(targetPath(), 'shared_preferences.json'),
        ).readAsStringSync(),
        '{"unit_system":"metric"}',
      );
    });

    test('is a no-op when the legacy and target names are identical', () async {
      seedLegacy();

      final report = await migrateCompanyDirectory(
        rootPath: root.path,
        legacyCompany: 'Eric Griffin',
        company: 'Eric Griffin',
        product: 'submersion',
      );

      expect(report.outcome, AppDataMigrationOutcome.notNeeded);
      expect(Directory(legacyPath()).existsSync(), isTrue);
    });

    test(
      'copies the tree when rename fails, keeping the legacy directory',
      () async {
        seedLegacy();

        final report = await migrate(
          rename: (_, _) => Future<Directory>.error(
            const FileSystemException('cross-device link'),
          ),
        );

        expect(report.outcome, AppDataMigrationOutcome.copied);
        expect(
          File(
            p.join(targetPath(), 'logs', 'submersion-debug.log'),
          ).readAsStringSync(),
          'line one',
        );
        // The legacy tree is deliberately retained: if the app dies mid-copy the
        // user still has one intact copy.
        expect(Directory(legacyPath()).existsSync(), isTrue);
      },
    );

    test('reports failure without deleting the legacy directory', () async {
      seedLegacy();
      // A FILE where the new company directory needs to be, so creating the
      // target parent cannot succeed.
      File(
        p.join(root.path, 'Submersion'),
      ).writeAsStringSync('not a directory');

      final report = await migrate();

      expect(report.outcome, AppDataMigrationOutcome.failed);
      expect(report.error, isNotNull);
      expect(Directory(legacyPath()).existsSync(), isTrue);
      expect(
        File(
          p.join(legacyPath(), 'shared_preferences.json'),
        ).readAsStringSync(),
        '{"unit_system":"metric"}',
      );
    });

    test('reports the paths it considered', () async {
      seedLegacy();

      final report = await migrate();

      expect(report.legacyPath, legacyPath());
      expect(report.targetPath, targetPath());
    });
  });

  group('migrateWindowsAppDataDirectories', () {
    test('does nothing off Windows', () async {
      final reports = await migrateWindowsAppDataDirectories();

      expect(reports, isEmpty, skip: Platform.isWindows);
    });
  });
}
