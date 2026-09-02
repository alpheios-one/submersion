// Regression test for issue #279: dives exported directly from the Oceanic+
// app (Apple Watch Ultra) imported with no dive profile, while the same dives
// routed through MacDive first imported fine.
//
// This exercises the full path the app uses for a UDDF file: parse with
// ExportService, then persist with UddfEntityImporter against an in-memory
// AppDatabase, then read the dive back through DiveRepository. The fixture is
// the real export attached to the issue.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/core/services/export/export_service.dart';
import 'package:submersion/features/buddies/data/repositories/buddy_repository.dart';
import 'package:submersion/features/certifications/data/repositories/certification_repository.dart';
import 'package:submersion/features/courses/data/repositories/course_repository.dart';
import 'package:submersion/features/dive_centers/data/repositories/dive_center_repository.dart';
import 'package:submersion/features/dive_import/data/services/uddf_entity_importer.dart';
import 'package:submersion/features/dive_log/data/repositories/dive_repository_impl.dart';
import 'package:submersion/features/dive_log/data/repositories/tank_pressure_repository.dart';
import 'package:submersion/features/dive_sites/data/repositories/site_repository_impl.dart';
import 'package:submersion/features/dive_types/data/repositories/dive_type_repository.dart';
import 'package:submersion/features/divers/data/repositories/diver_repository.dart';
import 'package:submersion/features/divers/domain/entities/diver.dart'
    as domain;
import 'package:submersion/features/equipment/data/repositories/equipment_repository_impl.dart';
import 'package:submersion/features/equipment/data/repositories/equipment_set_repository_impl.dart';
import 'package:submersion/features/tags/data/repositories/tag_repository.dart';
import 'package:submersion/features/trips/data/repositories/trip_repository.dart';

import '../../helpers/test_database.dart';

const _fixturePath = 'test/dives/issue_279_oceanic_plus_export.uddf';

ImportRepositories _buildRepositories() {
  return ImportRepositories(
    tripRepository: TripRepository(),
    equipmentRepository: EquipmentRepository(),
    equipmentSetRepository: EquipmentSetRepository(),
    buddyRepository: BuddyRepository(),
    diveCenterRepository: DiveCenterRepository(),
    certificationRepository: CertificationRepository(),
    tagRepository: TagRepository(),
    diveTypeRepository: DiveTypeRepository(),
    siteRepository: SiteRepository(),
    diveRepository: DiveRepository(),
    tankPressureRepository: TankPressureRepository(),
    courseRepository: CourseRepository(),
  );
}

Future<String> _createTestDiver() async {
  final now = DateTime.now();
  const diverId = 'diver-issue-279';
  await DiverRepository().createDiver(
    domain.Diver(
      id: diverId,
      name: 'Test Diver',
      isDefault: true,
      createdAt: now,
      updatedAt: now,
    ),
  );
  return diverId;
}

void main() {
  late AppDatabase db;
  final importer = UddfEntityImporter();
  final exportService = ExportService();
  late String content;

  setUpAll(() {
    content = File(_fixturePath).readAsStringSync();
  });

  setUp(() async {
    db = await setUpTestDatabase();
  });

  tearDown(() async {
    await tearDownTestDatabase();
  });

  group('Oceanic+ direct export (issue #279)', () {
    test('parser yields a profile for every dive', () async {
      final parsed = await exportService.importAllDataFromUddf(content);

      expect(parsed.dives, hasLength(9));
      for (final dive in parsed.dives) {
        final profile = dive['profile'] as List<Map<String, dynamic>>?;
        expect(profile, isNotNull);
        expect(profile!.length, greaterThan(50));
        // Timestamps advance at the 15 s Oceanic+ cadence instead of
        // collapsing to zero.
        expect(profile[1]['timestamp'], 15);
        expect(profile[2]['timestamp'], 30);
      }
    });

    test('persisted dives read back with their full profile', () async {
      final diverId = await _createTestDiver();
      final parsed = await exportService.importAllDataFromUddf(content);

      await importer.import(
        data: parsed,
        selections: UddfImportSelections.selectAll(parsed),
        repositories: _buildRepositories(),
        diverId: diverId,
      );

      final diveRepo = DiveRepository();
      final dives = await diveRepo.getAllDives();
      expect(dives, hasLength(9));

      final sampleRows = await db.select(db.diveProfileSeries).get();
      expect(sampleRows, isNotEmpty);

      for (final summary in dives) {
        final dive = await diveRepo.getDiveById(summary.id);
        expect(dive, isNotNull);
        expect(
          dive!.profile.length,
          greaterThan(50),
          reason: 'dive ${dive.id} lost its profile on import',
        );
        expect(dive.profile.first.timestamp, 0);
        expect(dive.profile[1].timestamp, 15);
        expect(dive.maxDepth, greaterThan(5));
        expect(dive.runtime, isNotNull);
        expect(dive.runtime!.inSeconds, greaterThan(1000));
      }
    });
  });
}
