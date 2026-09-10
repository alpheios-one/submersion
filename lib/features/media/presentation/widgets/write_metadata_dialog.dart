import 'package:flutter/material.dart';

import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/media/data/services/metadata_write_service.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// Dialog for confirming write of dive metadata to a photo.
///
/// Shows a preview of the metadata that will be written and warns about the
/// modification. Videos are not offered: writing to one meant replacing the
/// asset and deleting the original, which Submersion never does (issue #1472).
class WriteMetadataDialog extends StatelessWidget {
  final MediaItem item;
  final AppSettings settings;
  final String? siteName;

  const WriteMetadataDialog({
    super.key,
    required this.item,
    required this.settings,
    this.siteName,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final enrichment = item.enrichment;
    final formatter = UnitFormatter(settings);

    final metadata = DiveMediaMetadata.fromMediaItem(item, siteName: siteName);

    return AlertDialog(
      title: Text(context.l10n.media_writeMetadata_titlePhoto),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.l10n.media_writeMetadata_descriptionPhoto,
              style: textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),

            // Metadata preview
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  // Depth
                  if (enrichment?.depthMeters != null)
                    _MetadataRow(
                      icon: Icons.arrow_downward,
                      label: context.l10n.media_writeMetadata_depthLabel,
                      value: formatter.formatDepth(
                        enrichment!.depthMeters,
                        decimals: 1,
                      ),
                    ),

                  // Temperature
                  if (enrichment?.temperatureCelsius != null) ...[
                    const SizedBox(height: 8),
                    _MetadataRow(
                      icon: Icons.thermostat,
                      label: context.l10n.media_writeMetadata_temperatureLabel,
                      value: formatter.formatTemperature(
                        enrichment!.temperatureCelsius,
                        decimals: 0,
                      ),
                    ),
                  ],

                  // GPS
                  if (item.latitude != null && item.longitude != null) ...[
                    const SizedBox(height: 8),
                    _MetadataRow(
                      icon: Icons.location_on,
                      label: context.l10n.media_writeMetadata_gpsLabel,
                      value: formatter.formatCoordinates(
                        item.latitude,
                        item.longitude,
                      ),
                    ),
                  ],

                  // Elapsed time
                  if (enrichment?.elapsedSeconds != null) ...[
                    const SizedBox(height: 8),
                    _MetadataRow(
                      icon: Icons.timer_outlined,
                      label: context.l10n.media_writeMetadata_diveTimeLabel,
                      value: _formatElapsedTime(enrichment!.elapsedSeconds!),
                    ),
                  ],

                  // Site name
                  if (siteName != null && siteName!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _MetadataRow(
                      icon: Icons.place,
                      label: context.l10n.media_writeMetadata_siteLabel,
                      value: siteName!,
                    ),
                  ],

                  // No data warning
                  if (!metadata.hasData)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        context.l10n.media_writeMetadata_noDataAvailable,
                        style: textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            _buildWarningSection(context, colorScheme, textTheme),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(context.l10n.media_writeMetadata_cancelButton),
        ),
        FilledButton(
          onPressed: metadata.hasData
              ? () => Navigator.of(context).pop(true)
              : null,
          child: Text(context.l10n.media_writeMetadata_writeButton),
        ),
      ],
    );
  }

  Widget _buildWarningSection(
    BuildContext context,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: colorScheme.error, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              context.l10n.media_writeMetadata_warningPhotoText,
              style: textTheme.bodySmall?.copyWith(color: colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }

  String _formatElapsedTime(int seconds) {
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    return '+$minutes:${secs.toString().padLeft(2, '0')}';
  }
}

/// Row showing a single metadata item with icon.
class _MetadataRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _MetadataRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      label: '$label: $value',
      child: Row(
        children: [
          ExcludeSemantics(
            child: Icon(icon, size: 18, color: colorScheme.primary),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// Shows the write metadata dialog.
///
/// Returns true if the user confirmed the write, false if they cancelled or
/// dismissed the dialog.
Future<bool> showWriteMetadataDialog({
  required BuildContext context,
  required MediaItem item,
  required AppSettings settings,
  String? siteName,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) =>
        WriteMetadataDialog(item: item, settings: settings, siteName: siteName),
  );
  return result ?? false;
}
