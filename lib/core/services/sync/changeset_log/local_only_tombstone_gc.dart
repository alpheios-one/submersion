import 'package:submersion/core/data/repositories/sync_repository.dart';
import 'package:submersion/core/services/logger_service.dart';
import 'package:submersion/core/services/sync/changeset_log/peer_cursor_store.dart';
import 'package:submersion/core/services/sync/changeset_log/publish_state_store.dart';
import 'package:submersion/core/services/sync/changeset_log/sync_liveness.dart';

/// Every durable trace that this device has taken part in a sync, read once
/// so the GC decision is a pure function of them.
///
/// Sign-out clears only the provider and the remote file id, so the other
/// four survive it and keep a formerly synced device from purging tombstones
/// its cloud log still owes a peer. The user-facing Reset Sync State wipes the
/// cursor and publish rows and the last sync time but leaves the accepted
/// epoch, which is why the epoch is read as well.
class SyncHistoryEvidence {
  const SyncHistoryEvidence({
    required this.providerConfigured,
    required this.hasLastSyncTime,
    required this.hasPeerCursors,
    required this.hasPublishState,
    required this.hasAcceptedEpoch,
  });

  /// A cloud provider is connected. The cloud path owns GC in that case: it
  /// computes the fleet-acked horizon from live peer manifests at the tail of
  /// every successful sync.
  final bool providerConfigured;

  /// `sync_metadata.lastSyncTimestamp` is set.
  final bool hasLastSyncTime;

  /// At least one `sync_peer_cursors` row: this device consumed a peer's log.
  final bool hasPeerCursors;

  /// At least one `local_publish_states` row: this device published a base or
  /// adopted one. The only trace a single-device cloud library leaves.
  final bool hasPublishState;

  /// `sync_metadata.lastAcceptedEpochId` is set.
  final bool hasAcceptedEpoch;

  bool get hasEverSynced =>
      hasLastSyncTime || hasPeerCursors || hasPublishState || hasAcceptedEpoch;

  /// Tombstones may be purged past the floor only on a device that has no
  /// provider connected AND has never synced. A never-synced device has no
  /// peer that could hold the deleted rows, and a device joining a library
  /// later adopts the cloud's base rather than replaying this log. A device
  /// that has synced and then went local-only must keep its tombstones: the
  /// peers it left behind still need them to converge when it returns.
  bool get allowsLocalOnlyGc => !providerConfigured && !hasEverSynced;

  @override
  String toString() =>
      'SyncHistoryEvidence(provider: $providerConfigured, '
      'lastSync: $hasLastSyncTime, peerCursors: $hasPeerCursors, '
      'publishState: $hasPublishState, epoch: $hasAcceptedEpoch)';
}

/// Reaches tombstone GC on a device that never syncs.
///
/// `SyncRepository.clearAcknowledgedDeletions` is otherwise called from
/// exactly one place, the tail of a successful cloud sync, so a library that
/// never configured a provider keeps every tombstone forever. This runs the
/// same deletion with the same 30-day floor and a null horizon, which is the
/// branch the cloud path already takes when no live peer constrains it
/// (`TombstoneGcDecision.unbounded()`): a never-synced device is that case
/// with an empty fleet.
///
/// Runs on every launch, unawaited, in the shape of `MediaOrphanBacklogSweep`:
/// the probe is one metadata read and two indexed existence checks, and the
/// delete is a no-op on a library with nothing past the floor.
///
/// Known residual: a user who runs Reset Sync State and then signs out erases
/// every trace in [SyncHistoryEvidence], so a reconnect more than 30 days
/// later could resurrect rows deleted in between. That pair of actions is
/// already a deliberate cold start of the sync transport.
class LocalOnlyTombstoneGc {
  LocalOnlyTombstoneGc({
    required SyncRepository syncRepository,
    required PeerCursorStore peerCursors,
    required PublishStateStore publishStates,
  }) : _syncRepository = syncRepository,
       _peerCursors = peerCursors,
       _publishStates = publishStates;

  final SyncRepository _syncRepository;
  final PeerCursorStore _peerCursors;
  final PublishStateStore _publishStates;
  final _log = LoggerService.forClass(LocalOnlyTombstoneGc);

  Future<SyncHistoryEvidence> gatherEvidence() async {
    return SyncHistoryEvidence(
      providerConfigured: await _syncRepository.getCloudProvider() != null,
      hasLastSyncTime: await _syncRepository.getLastSyncTime() != null,
      hasPeerCursors: await _peerCursors.hasAny(),
      hasPublishState: await _publishStates.hasAny(),
      hasAcceptedEpoch: await _syncRepository.getLastAcceptedEpochId() != null,
    );
  }

  /// Returns whether a purge ran. Throws on repository failure so the caller
  /// can log it; the next launch simply runs again.
  Future<bool> run({DateTime? now}) async {
    final evidence = await gatherEvidence();
    if (!evidence.allowsLocalOnlyGc) return false;

    final at = now ?? DateTime.now();
    await _syncRepository.clearAcknowledgedDeletions(
      upToHlc: null,
      floorCutoffMillis: at.millisecondsSinceEpoch - SyncLiveness.gcFloorMillis,
    );
    _log.info('Local-only tombstone GC ran: $evidence');
    return true;
  }
}
