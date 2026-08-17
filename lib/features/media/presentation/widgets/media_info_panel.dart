import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/dive_log/presentation/widgets/dive_detail_row.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/domain/entities/media_provenance.dart';
import 'package:submersion/features/media/domain/entities/media_source_type.dart';
import 'package:submersion/features/media/domain/value_objects/media_source_data.dart';
import 'package:submersion/features/media/presentation/providers/media_provenance_providers.dart';
import 'package:submersion/features/media/presentation/providers/media_serving_providers.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';
import 'package:submersion/l10n/l10n_extension.dart';
import 'package:submersion/shared/utils/byte_format.dart';

/// Everything the app knows about where one media item came from, whether it
/// is backed up, and where its bytes are being served from right now.
///
/// Read-only. Every fix this panel might offer belongs to a later change; the
/// point here is that none of these facts were visible anywhere before.
class MediaInfoPanel extends ConsumerWidget {
  const MediaInfoPanel({super.key, required this.item, this.scrollController});

  final MediaItem item;

  /// Supplied when hosted in a DraggableScrollableSheet, which owns scrolling.
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final provenance = ref.watch(mediaProvenanceProvider(item));
    final units = UnitFormatter(ref.watch(settingsProvider));

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.all(16),
      children: [
        Text(l10n.media_info_title, style: _titleStyle(context)),
        const SizedBox(height: 16),
        _FileSection(item: item, units: units),
        const SizedBox(height: 12),
        _OriginSection(origin: provenance.origin, units: units),
        const SizedBox(height: 12),
        _BackupSection(backup: provenance.backup, units: units),
        const SizedBox(height: 12),
        _ServingSection(item: item),
      ],
    );
  }

  static TextStyle? _titleStyle(BuildContext context) =>
      Theme.of(context).textTheme.titleLarge;
}

/// A titled card of label/value rows, matching the dive detail convention.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const Divider(),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _FileSection extends StatelessWidget {
  const _FileSection({required this.item, required this.units});

  final MediaItem item;
  final UnitFormatter units;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final unknown = l10n.media_info_unknown;
    final width = item.width;
    final height = item.height;
    final size = item.contentSizeBytes;
    final lat = item.latitude;
    final lon = item.longitude;

    return _Section(
      title: l10n.media_info_fileSection,
      children: [
        DiveDetailRow(
          label: l10n.media_info_filename,
          value: item.originalFilename ?? unknown,
        ),
        DiveDetailRow(
          label: l10n.media_info_type,
          value: mediaTypeLabel(l10n, item.mediaType),
        ),
        DiveDetailRow(
          label: l10n.media_info_dimensions,
          // Pixels are unit-system invariant, so this is one of the few
          // displayed quantities the diver's unit settings do not touch.
          value: (width != null && height != null)
              ? '$width x $height'
              : unknown,
        ),
        DiveDetailRow(
          label: l10n.media_info_size,
          value: size == null ? unknown : formatBytes(size),
        ),
        DiveDetailRow(
          label: l10n.media_info_taken,
          // takenAt is non-nullable on the row, so there is no unknown case.
          value: units.formatDateTime(item.takenAt, l10n: l10n),
        ),
        if (lat != null && lon != null)
          DiveDetailRow(
            label: l10n.media_info_coordinates,
            value: '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}',
          ),
      ],
    );
  }
}

class _OriginSection extends ConsumerWidget {
  const _OriginSection({required this.origin, required this.units});

  final OriginFacts origin;
  final UnitFormatter units;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final deviceId = origin.originDeviceId;
    final thisDevice = ref.watch(currentDeviceIdProvider).value;

    return _Section(
      title: l10n.media_info_originSection,
      children: [
        DiveDetailRow(
          label: l10n.media_info_source,
          value: sourceTypeLabel(l10n, origin.sourceType),
        ),
        if (origin.pointer != null)
          DiveDetailRow(
            label: l10n.media_info_reference,
            value: origin.pointer!,
          ),
        // Omitted entirely when null. Null means this source type does not
        // track an origin device, NOT that the link was made here, so
        // rendering "This device" would state a fact the app never recorded
        // and would do it on every gallery photo.
        if (deviceId != null)
          DiveDetailRow(
            label: l10n.media_info_linkedOn,
            // Until this device's own id resolves, "another device" would be
            // a guess, so an unresolved id reads as this device: the row was
            // stamped locally in the overwhelmingly common case.
            value: (thisDevice == null || deviceId == thisDevice)
                ? l10n.media_info_thisDevice
                : l10n.media_info_otherDevice,
          ),
        DiveDetailRow(
          label: l10n.media_info_status,
          value: switch (origin.health) {
            OriginHealth.healthy => l10n.media_info_statusFound,
            OriginHealth.missing => l10n.media_info_statusMissing,
            OriginHealth.neverVerified => l10n.media_info_statusUnchecked,
          },
        ),
        if (origin.lastVerifiedAt != null)
          DiveDetailRow(
            label: '',
            value: l10n.media_info_lastChecked(
              units.formatDateTime(origin.lastVerifiedAt, l10n: l10n),
            ),
          ),
      ],
    );
  }
}

class _BackupSection extends ConsumerWidget {
  const _BackupSection({required this.backup, required this.units});

  final BackupFacts backup;
  final UnitFormatter units;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final identity = ref.watch(mediaStoreIdentityProvider).value;

    return _Section(
      title: l10n.media_info_backupSection,
      children: [
        DiveDetailRow(
          label: l10n.media_info_store,
          value: identity?.displayHint ?? l10n.media_info_storeNotConnected,
        ),
        DiveDetailRow(label: '', value: _summary(l10n)),
        if (backup.originalUploadedAt != null)
          DiveDetailRow(
            label: '',
            value: l10n.media_info_uploadedOn(
              units.formatDateTime(backup.originalUploadedAt, l10n: l10n),
            ),
          ),
        if (_queueLine(l10n) != null)
          DiveDetailRow(label: '', value: _queueLine(l10n)!),
      ],
    );
  }

  /// Precedence matters: an ineligible source is not "not backed up", it is
  /// something the pipeline would never carry, and saying otherwise reads as
  /// a problem the user could fix.
  String _summary(AppLocalizations l10n) {
    if (!backup.eligible) return l10n.media_info_notEligible;
    if (!backup.storeAttached) return l10n.media_info_storeNotConnected;
    return switch (backup.tier) {
      BackupTier.full => l10n.media_info_backupFull,
      BackupTier.thumbOnly => l10n.media_info_backupThumbOnly,
      BackupTier.renditionOnly => l10n.media_info_backupRenditionOnly,
      BackupTier.none => l10n.media_info_backupNone,
    };
  }

  /// A settled row says nothing new, so 'done' and an absent row both read as
  /// no queue line at all.
  String? _queueLine(AppLocalizations l10n) => switch (backup.queueState) {
    'pending' => l10n.media_info_queuePending,
    'transferring' => l10n.media_info_queueTransferring,
    'failed' => l10n.media_info_queueFailed(
      backup.queueError ?? l10n.media_info_unknown,
    ),
    _ => null,
  };
}

class _ServingSection extends ConsumerWidget {
  const _ServingSection({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final recorder = ref.watch(mediaServingRecorderProvider);

    // Read through a ListenableBuilder rather than a provider. Riverpod 3
    // auto-pause trips an assertion on providers that self-invalidate from a
    // listener the framework cannot see, and the repo's fix for that
    // (Ref.invalidateSelfWhen) takes a Stream, which a ChangeNotifier is not.
    return ListenableBuilder(
      listenable: recorder,
      builder: (context, _) {
        final facts = ServingFacts.from(
          recorder.lastFor(item.id, thumbnail: false),
        );
        return _Section(
          title: l10n.media_info_servingSection,
          children: [
            DiveDetailRow(label: '', value: _summary(l10n, facts)),
            if (facts.observed &&
                facts.storeFallbackUsed &&
                facts.servedFrom != null)
              DiveDetailRow(
                label: '',
                value: l10n.media_info_servingFallbackNote,
              ),
          ],
        );
      },
    );
  }

  String _summary(AppLocalizations l10n, ServingFacts facts) {
    if (!facts.observed) return l10n.media_info_servingUnobserved;
    final from = facts.servedFrom;
    if (from == null) return l10n.media_info_servingFailed;
    // Exhaustive with no default arm, so a new ServedFrom value becomes a
    // compile error rather than a silently wrong label.
    final source = switch (from) {
      ServedFrom.localDisk => l10n.media_info_servedLocalDisk,
      ServedFrom.platformGallery => l10n.media_info_servedGallery,
      ServedFrom.storeCache => l10n.media_info_servedStoreCache,
      ServedFrom.storeNetwork => l10n.media_info_servedStoreNetwork,
      ServedFrom.networkUrl => l10n.media_info_servedNetworkUrl,
      ServedFrom.connectorCache => l10n.media_info_servedConnectorCache,
      ServedFrom.connectorNetwork => l10n.media_info_servedConnectorNetwork,
      ServedFrom.embedded => l10n.media_info_servedEmbedded,
    };
    final tier = switch (facts.servedTier) {
      ServedTier.original => null,
      ServedTier.thumbnail => l10n.media_info_servingTierThumbnail,
      ServedTier.rendition => l10n.media_info_servingTierRendition,
    };
    return tier == null ? source : '$source ($tier)';
  }
}

/// Localized name for a media type.
///
/// MediaType.name would render the raw enum identifier, so a signature would
/// read as "instructorSignature" in every language. MediaType.displayName is
/// hardcoded English, which is no better in a panel that is localized
/// everywhere else.
String mediaTypeLabel(AppLocalizations l10n, MediaType type) => switch (type) {
  MediaType.photo => l10n.media_info_typePhoto,
  MediaType.video => l10n.media_info_typeVideo,
  MediaType.document => l10n.media_info_typeDocument,
  MediaType.instructorSignature => l10n.media_info_typeSignature,
};

/// Localized name for a source type.
///
/// Reuses the existing media_source_* keys rather than adding a parallel set,
/// so the panel and the Media console's Sources view can never disagree about
/// what a source type is called.
String sourceTypeLabel(AppLocalizations l10n, MediaSourceType type) =>
    switch (type) {
      MediaSourceType.platformGallery => l10n.media_source_gallery,
      MediaSourceType.localFile => l10n.media_source_localFile,
      MediaSourceType.networkUrl => l10n.media_source_networkUrl,
      MediaSourceType.manifestEntry => l10n.media_source_manifest,
      MediaSourceType.serviceConnector => l10n.media_source_connector,
      MediaSourceType.mediaStore => l10n.media_source_mediaStore,
      MediaSourceType.signature => l10n.media_source_signature,
    };
