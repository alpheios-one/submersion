import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'package:submersion/features/media/data/repositories/media_repository.dart';
import 'package:submersion/features/media/data/resolvers/local_file_resolver.dart';
import 'package:submersion/features/media/data/services/local_files_diagnostics_service.dart';
import 'package:submersion/features/media/data/services/local_media_platform.dart';
import 'package:submersion/features/media/data/services/media_verification_sweep.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/domain/entities/media_source_type.dart';

import 'local_files_diagnostics_service_test.mocks.dart';

/// Records the filter it was handed and returns a canned outcome. Hand
/// written rather than generated: mocking the sweep would let a signature
/// change pass silently until the next build_runner run.
class _StubSweep implements MediaVerificationSweep {
  _StubSweep(this.outcome);

  final SweepOutcome outcome;
  final List<Set<MediaSourceType>?> asked = [];

  @override
  Future<SweepOutcome> run({
    Set<MediaSourceType>? sourceTypes,
    void Function(int done, int total)? onProgress,
  }) async {
    asked.add(sourceTypes);
    return outcome;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not stubbed');
}

@GenerateMocks([MediaRepository, LocalFileResolver, LocalMediaPlatform])
void main() {
  late MockMediaRepository mockRepo;
  late MockLocalMediaPlatform mockPlatform;
  late _StubSweep idleSweep;
  late LocalFilesDiagnosticsService subject;

  setUp(() {
    mockRepo = MockMediaRepository();
    mockPlatform = MockLocalMediaPlatform();
    idleSweep = _StubSweep(
      const SweepOutcome(processed: 0, flipped: 0, inconclusive: 0, failed: 0),
    );
    subject = LocalFilesDiagnosticsService(
      repository: mockRepo,
      sweep: idleSweep,
      platform: mockPlatform,
    );
  });

  MediaItem item({
    String id = 'm1',
    bool isOrphaned = false,
    DateTime? lastVerifiedAt,
  }) {
    return MediaItem(
      id: id,
      mediaType: MediaType.photo,
      sourceType: MediaSourceType.localFile,
      isOrphaned: isOrphaned,
      lastVerifiedAt: lastVerifiedAt,
      takenAt: DateTime(2024),
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
    );
  }

  group('diagnose', () {
    test(
      'returns total/available/unavailable counts based on isOrphaned flag',
      () async {
        when(mockRepo.getAllBySourceType(MediaSourceType.localFile)).thenAnswer(
          (_) async => [
            item(id: 'a', isOrphaned: false),
            item(id: 'b', isOrphaned: false),
            item(id: 'c', isOrphaned: true),
          ],
        );

        final result = await subject.diagnose();

        expect(result.total, 3);
        expect(result.available, 2);
        expect(result.unavailable, 1);
        // Read path must never touch the filesystem: it reports the
        // persisted flag and must not trigger a sweep.
        expect(idleSweep.asked, isEmpty);
      },
    );

    test('with empty repository returns zeros', () async {
      when(
        mockRepo.getAllBySourceType(MediaSourceType.localFile),
      ).thenAnswer((_) async => []);

      final result = await subject.diagnose();

      expect(result.total, 0);
      expect(result.available, 0);
      expect(result.unavailable, 0);
    });
  });

  group('reverifyAll', () {
    // The sweep loop itself moved to MediaVerificationSweep, and its
    // behaviour (flip counting, inconclusive results, per-item failures) is
    // covered by media_verification_sweep_test.dart. What belongs here is the
    // delegation contract: the local-files subsection must keep asking for
    // local files only, and must keep returning the flipped count its
    // snackbar shows.
    test('delegates to the sweep filtered to local files', () async {
      final sweep = _StubSweep(
        const SweepOutcome(
          processed: 9,
          flipped: 2,
          inconclusive: 0,
          failed: 0,
        ),
      );
      final subject = LocalFilesDiagnosticsService(
        repository: mockRepo,
        sweep: sweep,
        platform: mockPlatform,
      );

      final flipped = await subject.reverifyAll();

      expect(flipped, 2);
      expect(sweep.asked.single, {MediaSourceType.localFile});
    });

    test('reports zero when nothing changed', () async {
      final sweep = _StubSweep(
        const SweepOutcome(
          processed: 9,
          flipped: 0,
          inconclusive: 9,
          failed: 0,
        ),
      );
      final subject = LocalFilesDiagnosticsService(
        repository: mockRepo,
        sweep: sweep,
        platform: mockPlatform,
      );

      expect(await subject.reverifyAll(), 0);
    });
  });

  group('LocalFilesDiagnostics equality (Equatable)', () {
    test('two instances with same fields are equal', () {
      const a = LocalFilesDiagnostics(total: 3, available: 2, unavailable: 1);
      const b = LocalFilesDiagnostics(total: 3, available: 2, unavailable: 1);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('instances with different fields are not equal', () {
      const a = LocalFilesDiagnostics(total: 3, available: 2, unavailable: 1);
      const b = LocalFilesDiagnostics(total: 3, available: 1, unavailable: 2);
      expect(a, isNot(equals(b)));
    });
  });

  group('androidUriUsage', () {
    // We don't test the Android-list-length branch: this suite runs on macOS
    // hosts, where the `Platform.isAndroid` short-circuit prevents the
    // platform mock from being consulted regardless of stub setup. See the
    // service's androidUriUsage doc comment for details.
    test('returns 0 on non-Android', () async {
      final result = await subject.androidUriUsage();

      expect(result, 0);
      verifyNever(mockPlatform.listPersistedUris());
    });
  });
}
