import 'package:submersion/features/media/data/repositories/media_repository.dart';

/// Records [markVerified] calls and refuses every other member, so a write
/// the code under test was not supposed to make shows up as a failure rather
/// than as a silently accepted no-op.
///
/// Shared by every test that exercises MediaItemView's orphan-flag
/// reconciliation, whether directly or through a tile that embeds the view.
class CapturingMediaRepository implements MediaRepository {
  final List<({String id, bool isOrphaned})> writes = [];

  @override
  Future<void> markVerified(
    String id, {
    required bool isOrphaned,
    required DateTime verifiedAt,
  }) async => writes.add((id: id, isOrphaned: isOrphaned));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not stubbed');
}
