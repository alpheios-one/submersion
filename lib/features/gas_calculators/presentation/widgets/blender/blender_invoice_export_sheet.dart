import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:submersion/core/services/export/export_service.dart';
import 'package:submersion/core/utils/share_anchor.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// Bottom sheet offering the three export formats for the running bill.
///
/// A sheet rather than a bare popup menu because it needs enough vertical
/// room for a title, three tappable rows and their loading state on the
/// narrowest supported phone (issue #1335 analysis).
class BlenderInvoiceExportSheet extends StatefulWidget {
  const BlenderInvoiceExportSheet({
    super.key,
    required this.data,
    required this.imageBoundaryKey,
  });

  final BlenderInvoiceExportData data;

  /// The [RepaintBoundary] wrapping the invoice card, captured for the image
  /// export. Simpler than redrawing the bill on a canvas, and it exports
  /// exactly what the diver is already looking at (issue #1335 analysis).
  final GlobalKey imageBoundaryKey;

  @override
  State<BlenderInvoiceExportSheet> createState() =>
      _BlenderInvoiceExportSheetState();
}

class _BlenderInvoiceExportSheetState extends State<BlenderInvoiceExportSheet> {
  bool _isExporting = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.l10n.gasCalculators_blender_export,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            _ExportOptionTile(
              key: const Key('blender-export-pdf'),
              icon: Icons.picture_as_pdf_outlined,
              title: context.l10n.gasCalculators_blender_exportPdf,
              isLoading: _isExporting,
              onTap: _isExporting ? null : _exportPdf,
            ),
            const SizedBox(height: 12),
            _ExportOptionTile(
              key: const Key('blender-export-image'),
              icon: Icons.image_outlined,
              title: context.l10n.gasCalculators_blender_exportImage,
              isLoading: _isExporting,
              onTap: _isExporting ? null : _exportImage,
            ),
            const SizedBox(height: 12),
            _ExportOptionTile(
              key: const Key('blender-export-excel'),
              icon: Icons.table_chart_outlined,
              title: context.l10n.gasCalculators_blender_exportExcel,
              isLoading: _isExporting,
              onTap: _isExporting ? null : _exportExcel,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportPdf(Rect? anchor) => _run(
    (anchor) => ExportService().exportBlenderInvoiceToPdf(
      widget.data,
      sharePositionOrigin: anchor,
    ),
    anchor,
  );

  Future<void> _exportExcel(Rect? anchor) => _run(
    (anchor) => ExportService().exportBlenderInvoiceToExcel(
      widget.data,
      sharePositionOrigin: anchor,
    ),
    anchor,
  );

  Future<void> _exportImage(Rect? anchor) => _run((anchor) async {
    final boundary =
        widget.imageBoundaryKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) {
      throw StateError('invoice card is not on screen');
    }
    final image = await boundary.toImage(pixelRatio: 2.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) {
      throw StateError('failed to encode invoice image');
    }
    final bytes = byteData.buffer.asUint8List();
    await ExportService().exportImageAsPng(
      bytes,
      'submersion_blender_invoice_${DateTime.now().millisecondsSinceEpoch}.png',
      sharePositionOrigin: anchor,
    );
  }, anchor);

  /// Runs one export [action], captured at tap time: the sheet dismisses
  /// itself on success, and by then the tapped tile's context is gone (same
  /// reasoning as [CertificationShareSheet]).
  Future<void> _run(
    Future<void> Function(Rect? anchor) action,
    Rect? anchor,
  ) async {
    setState(() => _isExporting = true);
    try {
      await action(anchor);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _isExporting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.gasCalculators_blender_exportError('$e'),
            ),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }
}

class _ExportOptionTile extends StatelessWidget {
  const _ExportOptionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    required this.isLoading,
  });

  final IconData icon;
  final String title;
  final void Function(Rect? anchor)? onTap;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap == null ? null : () => onTap!(shareAnchorFrom(context)),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, color: theme.colorScheme.primary, size: 24),
              const SizedBox(width: 16),
              Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
              if (isLoading)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  Icons.chevron_right,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
