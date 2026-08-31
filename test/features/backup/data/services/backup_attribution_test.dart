import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/backup/data/services/backup_attribution.dart';

void main() {
  const thisDevice = '9f8e7d6c-1111-2222-3333-444455556666';
  const otherDevice = '0a1b2c3d-1111-2222-3333-444455556666';

  group('buildBackupFilename', () {
    test('keeps the historic prefix and extension', () {
      final name = buildBackupFilename(
        timestamp: '2026-08-31_121314',
        deviceId: thisDevice,
      );

      // Several call sites match on the prefix (cloud listing, plaintext
      // cleanup) and on the extension. Attribution goes between them so none
      // of that has to change.
      expect(name, startsWith('submersion_backup_'));
      expect(name, endsWith('.db'));
      expect(name, contains('2026-08-31_121314'));
    });

    test('carries the device tag in the name, not just the record', () {
      final name = buildBackupFilename(
        timestamp: '2026-08-31_121314',
        deviceId: thisDevice,
      );

      // The whole point: an orphan is a file whose record is gone, so
      // attribution stored in the record is exactly the missing information.
      expect(backupDeviceTagFromFilename(name), isNotNull);
    });

    test('produces a filesystem-safe tag', () {
      final name = buildBackupFilename(
        timestamp: '2026-08-31_121314',
        deviceId: 'weird/id with spaces:and*chars',
      );

      expect(name, isNot(contains('/')));
      expect(name, isNot(contains(' ')));
      expect(name, isNot(contains(':')));
      expect(name, isNot(contains('*')));
    });

    test('the same device always produces the same tag', () {
      final a = buildBackupFilename(
        timestamp: '2026-08-31_121314',
        deviceId: thisDevice,
      );
      final b = buildBackupFilename(
        timestamp: '2026-09-01_010203',
        deviceId: thisDevice,
      );

      expect(backupDeviceTagFromFilename(a), backupDeviceTagFromFilename(b));
    });
  });

  group('backupDeviceTagFromFilename', () {
    test('reads the tag back from a name this app wrote', () {
      final name = buildBackupFilename(
        timestamp: '2026-08-31_121314',
        deviceId: thisDevice,
      );

      expect(backupDeviceTagFromFilename(name), deviceTag(thisDevice));
    });

    test('reads a tag from the encrypted variant too', () {
      final name = buildBackupFilename(
        timestamp: '2026-08-31_121314',
        deviceId: thisDevice,
      ).replaceAll('.db', '.sbe');

      expect(backupDeviceTagFromFilename(name), deviceTag(thisDevice));
    });

    test('a legacy name carries no tag', () {
      expect(
        backupDeviceTagFromFilename('submersion_backup_2026-08-31_121314.db'),
        isNull,
      );
    });

    test('an unrelated file carries no tag', () {
      expect(backupDeviceTagFromFilename('holiday_photos.db'), isNull);
      expect(backupDeviceTagFromFilename('.hidden.db.tmp'), isNull);
    });
  });

  group('classifyBackupFile', () {
    test('a backup this device wrote is claimed', () {
      final name = buildBackupFilename(
        timestamp: '2026-08-31_121314',
        deviceId: thisDevice,
      );

      expect(
        classifyBackupFile(filename: name, thisDeviceId: thisDevice),
        BackupOwnership.thisDevice,
      );
    });

    test('a backup another device wrote is never claimed', () {
      // The hazard this whole module exists for. The app tells users to point
      // the backup folder at Dropbox or Google Drive, so another device's
      // backups sit in the same directory and are absent from this device's
      // history. Deleting them would destroy the only copy they have.
      final name = buildBackupFilename(
        timestamp: '2026-08-31_121314',
        deviceId: otherDevice,
      );

      expect(
        classifyBackupFile(filename: name, thisDeviceId: thisDevice),
        BackupOwnership.otherDevice,
      );
    });

    test('a legacy backup is unattributed rather than claimed', () {
      // Attribution fixes the future, not the past: a file written before this
      // shipped can never be traced, so it must never be offered for deletion.
      expect(
        classifyBackupFile(
          filename: 'submersion_backup_2026-08-31_121314.db',
          thisDeviceId: thisDevice,
        ),
        BackupOwnership.unattributed,
      );
    });

    test('nothing is claimed when this device has no id yet', () {
      final name = buildBackupFilename(
        timestamp: '2026-08-31_121314',
        deviceId: thisDevice,
      );

      expect(
        classifyBackupFile(filename: name, thisDeviceId: ''),
        BackupOwnership.unattributed,
      );
    });
  });
}
