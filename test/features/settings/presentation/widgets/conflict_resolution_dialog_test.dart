import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/services/sync/conflict_reference.dart';
import 'package:submersion/core/services/sync/sync_service.dart';
import 'package:submersion/features/settings/presentation/providers/sync_providers.dart';
import 'package:submersion/features/settings/presentation/widgets/conflict_resolution_dialog.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../../helpers/mock_providers.dart';

/// Widget coverage for the Resolve Conflicts dialog's data preview (#1031).
/// Junction and relation entities carry nothing but foreign keys, so the
/// preview has to lead with the resolved references; showing raw UUIDs and an
/// epoch timestamp gives the user nothing to decide with.
void main() {
  final diveDate = DateTime(2026, 3, 28, 10, 0);

  Future<void> pumpDialog(WidgetTester tester, SyncConflict conflict) async {
    final base = await getBaseOverrides();
    await tester.binding.setSurfaceSize(const Size(600, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...base,
          conflictsProvider.overrideWith((ref) async => [conflict]),
        ],
        child: const MaterialApp(
          // Pinned so the English literals asserted below cannot depend on
          // the host's default locale.
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ConflictResolutionDialog()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  SyncConflict diveTagConflict({
    String localTagName = 'Wreck',
    bool tagMissing = false,
  }) => SyncConflict(
    entityType: 'diveTags',
    recordId: '7600a6e8-42b8-4375-b71b-e492b9406adb',
    localData: {
      'id': '7600a6e8-42b8-4375-b71b-e492b9406adb',
      'diveId': '889cb873-5517-41dc-8545-4bdb59307c38',
      'tagId': 'a7136f77-5628-4d6c-abaf-eed97f618cc8',
      'createdAt': 1786556582600,
    },
    remoteData: {
      'id': '7600a6e8-42b8-4375-b71b-e492b9406adb',
      'diveId': '889cb873-5517-41dc-8545-4bdb59307c38',
      'tagId': 'b1234567-5628-4d6c-abaf-eed97f618cc8',
      'createdAt': 1786556582600,
    },
    localModified: DateTime(2026, 3, 28),
    remoteModified: DateTime(2026, 3, 29),
    localReferences: [
      ConflictReference(
        field: 'diveId',
        targetType: 'dives',
        recordId: '889cb873-5517-41dc-8545-4bdb59307c38',
        name: 'Blue Hole',
        timestamp: diveDate,
      ),
      ConflictReference(
        field: 'tagId',
        targetType: 'tags',
        recordId: 'a7136f77-5628-4d6c-abaf-eed97f618cc8',
        name: tagMissing ? null : localTagName,
      ),
    ],
    remoteReferences: [
      ConflictReference(
        field: 'diveId',
        targetType: 'dives',
        recordId: '889cb873-5517-41dc-8545-4bdb59307c38',
        name: 'Blue Hole',
        timestamp: diveDate,
      ),
      const ConflictReference(
        field: 'tagId',
        targetType: 'tags',
        recordId: 'b1234567-5628-4d6c-abaf-eed97f618cc8',
        name: 'Night dive',
      ),
    ],
  );

  testWidgets('names the tag and the dive instead of printing their ids', (
    tester,
  ) async {
    await pumpDialog(tester, diveTagConflict());

    expect(find.text('Tag:'), findsNWidgets(2));
    expect(find.text('Dive:'), findsNWidgets(2));
    expect(find.text('Wreck'), findsOneWidget);
    expect(find.text('Night dive'), findsOneWidget);
    // "Blue Hole (28/03/2026)": the dive is named by its site and dated.
    // Both sides render one, on top of the composed header title.
    expect(find.textContaining('Blue Hole ('), findsNWidgets(2));
  });

  testWidgets('never shows a raw uuid or epoch millis in the preview', (
    tester,
  ) async {
    await pumpDialog(tester, diveTagConflict());

    expect(find.textContaining('a7136f77'), findsNothing);
    expect(find.textContaining('889cb873'), findsNothing);
    expect(find.textContaining('1786556582600'), findsNothing);
  });

  testWidgets('says so when a referenced record is gone locally', (
    tester,
  ) async {
    await pumpDialog(tester, diveTagConflict(tagMissing: true));

    expect(find.text('No longer in this library'), findsOneWidget);
  });

  testWidgets('describes the conflicting record in the header', (tester) async {
    await pumpDialog(tester, diveTagConflict());

    expect(find.text('Blue Hole \u2022 Wreck'), findsOneWidget);
    expect(find.text('Dive Tags'), findsOneWidget);
    expect(find.textContaining('7600a6e8'), findsNothing);
  });

  testWidgets('dates an epoch column but leaves a duration alone', (
    tester,
  ) async {
    // bottomTime and createdAt both end in a time-ish word, but bottomTime is
    // seconds and createdAt is Unix millis. Only the magnitude tells them
    // apart, so a naive name-only rule would date a 45-minute bottom time to
    // 1970.
    await pumpDialog(
      tester,
      SyncConflict(
        entityType: 'dives',
        recordId: 'd-1',
        localData: const {
          'id': 'd-1',
          'diveNumber': 12,
          'bottomTime': 2700,
          'createdAt': 1786556582600,
        },
        remoteData: const {
          'id': 'd-1',
          'diveNumber': 13,
          'bottomTime': 2700,
          'createdAt': 1786556582600,
        },
        localModified: DateTime(2026, 3, 28),
        remoteModified: DateTime(2026, 3, 29),
      ),
    );

    expect(find.text('2700'), findsNWidgets(2));
    expect(find.textContaining('1786556582600'), findsNothing);
  });

  testWidgets('renders a quality finding as its localized message', (
    tester,
  ) async {
    final finding = SyncConflict(
      entityType: 'qualityFindings',
      recordId: 'qf-1',
      localData: const {
        'id': 'qf-1',
        'diveId': '889cb873-5517-41dc-8545-4bdb59307c38',
        'detectorId': 'depth_spike',
        'detectorVersion': 1,
        'category': 'profile',
        'severity': 'warning',
        'status': 'open',
        'params': '{"depth":42.0,"atSeconds":185}',
        'createdAt': 1786556582600,
        'updatedAt': 1786556582600,
      },
      remoteData: const {
        'id': 'qf-1',
        'diveId': '889cb873-5517-41dc-8545-4bdb59307c38',
        'detectorId': 'depth_spike',
        'detectorVersion': 1,
        'category': 'profile',
        'severity': 'critical',
        'status': 'open',
        'params': '{"depth":42.0,"atSeconds":185}',
        'createdAt': 1786556582600,
        'updatedAt': 1786556582600,
      },
      localModified: DateTime(2026, 3, 28),
      remoteModified: DateTime(2026, 3, 29),
      localReferences: [
        ConflictReference(
          field: 'diveId',
          targetType: 'dives',
          recordId: '889cb873-5517-41dc-8545-4bdb59307c38',
          name: 'Blue Hole',
          timestamp: diveDate,
        ),
      ],
      remoteReferences: [
        ConflictReference(
          field: 'diveId',
          targetType: 'dives',
          recordId: '889cb873-5517-41dc-8545-4bdb59307c38',
          name: 'Blue Hole',
          timestamp: diveDate,
        ),
      ],
    );

    await pumpDialog(tester, finding);

    expect(find.textContaining('Depth spike'), findsWidgets);
    expect(find.textContaining('params'), findsNothing);
    expect(find.textContaining('detectorId'), findsNothing);
  });
}
