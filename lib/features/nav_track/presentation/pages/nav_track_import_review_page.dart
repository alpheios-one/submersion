import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_log/presentation/widgets/pickers/site_picker_sheet.dart';
import 'package:submersion/features/dive_sites/domain/entities/dive_site.dart';
import 'package:submersion/features/nav_track/data/services/nav_track_import_service.dart';
import 'package:submersion/features/nav_track/data/services/parsers/parsed_nav_track.dart';
import 'package:submersion/features/nav_track/domain/nav_track_segmenter.dart';
import 'package:submersion/features/nav_track/presentation/nav_track_parse_error_text.dart';
import 'package:submersion/features/nav_track/presentation/providers/nav_track_import_flow_providers.dart';
import 'package:submersion/features/nav_track/presentation/providers/nav_track_providers.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';

/// Pushes the route review page for [bytes] freshly picked/dropped as
/// [fileName] and returns once the diver leaves it (whether or not they
/// saved). Every entry point that recognises a Seacraft ENC file --
/// the universal import wizard's hand-off card, the GPS logger's "Import
/// track", the routes area's own import button, the dive detail section's
/// import button -- calls this rather than building the page itself, so a
/// route path or a button label never needs to be duplicated.
///
/// [preselectedDiveId] is a hint only, used to pre-select that dive in the
/// link proposal once the preview loads (e.g. importing from a dive's own
/// "Underwater Route" section, where the dive is already known); it does
/// not skip the parse or the review step.
Future<void> navigateToNavTrackReview(
  BuildContext context,
  Uint8List bytes, {
  required String fileName,
  String? preselectedDiveId,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => NavTrackImportReviewPage(
        bytes: bytes,
        fileName: fileName,
        preselectedDiveId: preselectedDiveId,
      ),
    ),
  );
}

/// Reviews a parsed Seacraft ENC route before it is written: the link
/// proposal, the dive site, warnings, and the save action (spec
/// 2026-09-10-underwater-nav-track-design.md, "Review page").
///
/// Parsing happens once, in [initState] (against the service's [prepare],
/// or reused from [preview] when a caller already parsed the file --
/// the routes area's own import button does this today through
/// `pendingNavTrackImportProvider`, to show its own error handling around
/// a failed parse before ever pushing this page); nothing is written until
/// [_save] calls its `commit`.
class NavTrackImportReviewPage extends ConsumerStatefulWidget {
  const NavTrackImportReviewPage({
    super.key,
    required this.bytes,
    required this.fileName,
    this.preselectedDiveId,
    this.preview,
  });

  final Uint8List bytes;
  final String fileName;
  final String? preselectedDiveId;

  /// Already-parsed preview, when a caller (e.g. the routes area's import
  /// button) ran `NavTrackImportService.prepare` itself. Null re-parses
  /// [bytes] in [initState].
  final NavTrackImportPreview? preview;

  @override
  ConsumerState<NavTrackImportReviewPage> createState() =>
      _NavTrackImportReviewPageState();
}

class _NavTrackImportReviewPageState
    extends ConsumerState<NavTrackImportReviewPage> {
  late final Future<NavTrackImportPreview> _previewFuture;

  Dive? _selectedDive;
  bool _diveChoiceInitialized = false;
  String? _siteId;
  String? _siteName;
  bool _replaceDuplicate = false;
  bool _busy = false;
  String? _error;

  final _nameController = TextEditingController();
  final _deviceController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _previewFuture = widget.preview != null
        ? Future.value(widget.preview)
        : ref
              .read(navTrackImportServiceProvider)
              .prepare(widget.bytes, fileName: widget.fileName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _deviceController.dispose();
    super.dispose();
  }

  /// The link proposal defaults to the unique overlap match, or to
  /// [widget.preselectedDiveId] when the caller already knows the dive;
  /// several candidates or none leave the route unlinked until the diver
  /// chooses. Runs once, the first time the preview is available.
  void _initializeDiveChoice(NavTrackImportPreview preview) {
    if (_diveChoiceInitialized) return;
    _diveChoiceInitialized = true;
    if (widget.preselectedDiveId != null) {
      _selectedDive = preview.candidateDives
          .where((d) => d.id == widget.preselectedDiveId)
          .firstOrNull;
    }
    _selectedDive ??= preview.candidateDives.length == 1
        ? preview.candidateDives.single
        : null;
  }

  Future<void> _pickSite() async {
    final result = await showModalBottomSheet<DiveSite>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (sheetContext, scrollController) => SitePickerSheet(
          scrollController: scrollController,
          selectedSiteId: _siteId,
          onSiteSelected: (site) => Navigator.of(sheetContext).pop(site),
          // Creating a brand-new site from mid-review is a separate flow
          // this page does not open; the diver can still pick one already
          // in their log, or leave the route unanchored and set a site
          // later from the routes area.
          onCreateNewSite: () => Navigator.of(sheetContext).pop(),
        ),
      ),
    );
    if (result != null) {
      setState(() {
        _siteId = result.id;
        _siteName = result.name;
      });
    }
  }

  String _segmentSummary(NavTrackSegmentation segmentation) {
    final underwater = segmentation.kinds
        .where((k) => k == NavTrackSampleKind.underwater)
        .length;
    final surface = segmentation.kinds
        .where((k) => k == NavTrackSampleKind.surfaceReckoned)
        .length;
    if (segmentation.fixEvents.isEmpty) {
      return '$underwater samples underwater, no GPS fix in this recording.';
    }
    final event = segmentation.fixEvents.first;
    final dNorth = event.afterNorth - event.beforeNorth;
    final dEast = event.afterEast - event.beforeEast;
    final vector = math.sqrt(dNorth * dNorth + dEast * dEast).round();
    return '$underwater samples underwater, $surface surface samples, '
        'GPS fix ${vector}m from the reckoned end.';
  }

  Future<void> _save(NavTrackImportPreview preview) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_replaceDuplicate && preview.duplicateOfRouteId != null) {
        await ref
            .read(navTrackRepositoryProvider)
            .delete(preview.duplicateOfRouteId!);
      }
      final name = _nameController.text.trim();
      final device = _deviceController.text.trim();
      final id = await ref
          .read(navTrackImportServiceProvider)
          .commit(
            parsed: preview.parsed,
            sourceRef: preview.sourceRef,
            dive: _selectedDive,
            siteId: _siteId,
            name: name.isEmpty ? null : name,
            deviceName: device.isEmpty ? null : device,
          );
      if (!mounted) return;
      // Literal path: the routes-area detail page lives in another agent's
      // work on this branch and is not yet guaranteed to exist under this
      // exact route name at the time this file is written.
      context.go('/nav-routes/$id');
    } on NavTrackParseException catch (e) {
      setState(() {
        _busy = false;
        _error = navTrackParseErrorText(e);
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Could not save this route: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final units = UnitFormatter(ref.watch(settingsProvider));

    return Scaffold(
      appBar: AppBar(title: const Text('Import Underwater Route')),
      body: FutureBuilder<NavTrackImportPreview>(
        future: _previewFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final error = snapshot.error;
          if (error != null) {
            final message = error is NavTrackParseException
                ? navTrackParseErrorText(error)
                : 'This file could not be imported: $error';
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(message, textAlign: TextAlign.center),
              ),
            );
          }
          final preview = snapshot.data!;
          _initializeDiveChoice(preview);
          return _buildReview(context, units, preview);
        },
      ),
    );
  }

  Widget _buildReview(
    BuildContext context,
    UnitFormatter units,
    NavTrackImportPreview preview,
  ) {
    final theme = Theme.of(context);
    final points = preview.parsed.points;
    final start = DateTime.fromMillisecondsSinceEpoch(
      points.first.timestamp * 1000,
      isUtc: true,
    );
    final end = DateTime.fromMillisecondsSinceEpoch(
      points.last.timestamp * 1000,
      isUtc: true,
    );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(preview.sourceRef, style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Seacraft ENC log',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _deviceController,
          decoration: const InputDecoration(
            labelText: 'Device (optional)',
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _nameController,
          decoration: const InputDecoration(
            labelText: 'Name (optional)',
            isDense: true,
          ),
        ),
        const SizedBox(height: 24),
        _SummaryGrid(units: units, preview: preview, start: start, end: end),
        const SizedBox(height: 16),
        Text(
          _segmentSummary(preview.segmentation),
          key: const ValueKey('nav-track-segment-summary'),
          style: theme.textTheme.bodyMedium,
        ),
        if (preview.hasNoMovement) ...[
          const SizedBox(height: 12),
          const _WarningCard(
            key: ValueKey('nav-track-warning-no-movement'),
            text:
                'No movement recorded: distance and speed stay at zero '
                'throughout this file.',
          ),
        ],
        if (preview.duplicateOfRouteId != null) ...[
          const SizedBox(height: 12),
          _WarningCard(
            key: const ValueKey('nav-track-warning-duplicate'),
            text:
                'This looks like a route already imported from the same '
                'file.',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Replace'),
                Checkbox(
                  value: _replaceDuplicate,
                  onChanged: (v) =>
                      setState(() => _replaceDuplicate = v ?? false),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
        Text('Link to dive', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        _DiveLinkPicker(
          candidates: preview.candidateDives,
          selected: _selectedDive,
          units: units,
          onChanged: (dive) => setState(() => _selectedDive = dive),
        ),
        const SizedBox(height: 24),
        Text('Dive site', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        ListTile(
          key: const ValueKey('nav-track-site-picker'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.place_outlined),
          title: Text(_siteName ?? 'No site chosen'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _pickSite,
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 24),
        FilledButton(
          key: const ValueKey('nav-track-import-save'),
          onPressed: _busy ? null : () => _save(preview),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _SummaryGrid extends StatelessWidget {
  const _SummaryGrid({
    required this.units,
    required this.preview,
    required this.start,
    required this.end,
  });

  final UnitFormatter units;
  final NavTrackImportPreview preview;
  final DateTime start;
  final DateTime end;

  @override
  Widget build(BuildContext context) {
    final stats = preview.stats;
    final duration = Duration(seconds: stats.durationSeconds);
    final durationText =
        '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
    final rows = <(String, String)>[
      ('Start', '${units.formatDate(start)} ${units.formatTime(start)}'),
      ('End', '${units.formatDate(end)} ${units.formatTime(end)}'),
      ('Duration', durationText),
      ('Distance', units.formatDistance(stats.totalDistance)),
      ('Max depth', units.formatDepth(stats.maxDepth)),
      if (stats.maxSpeed != null)
        ('Max speed', units.formatSpeed(stats.maxSpeed!)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(label),
                Text(
                  value,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DiveLinkPicker extends StatelessWidget {
  const _DiveLinkPicker({
    required this.candidates,
    required this.selected,
    required this.units,
    required this.onChanged,
  });

  final List<Dive> candidates;
  final Dive? selected;
  final UnitFormatter units;
  final ValueChanged<Dive?> onChanged;

  // A minimal inline picker: candidates ordered by NavTrackMatcher's own
  // overlap ranking, plus "leave unlinked". The fuller `DiveLinkPicker`
  // widget (design spec's own name for the shared dive/route picker) is
  // being built by another agent on this branch for the dive detail
  // section and the routes-area detail page; once it exists, this can
  // delegate to it instead of its own RadioListTile column.
  @override
  Widget build(BuildContext context) {
    return RadioGroup<String?>(
      groupValue: selected?.id,
      onChanged: (id) =>
          onChanged(candidates.where((d) => d.id == id).firstOrNull),
      child: Column(
        children: [
          const RadioListTile<String?>(
            key: ValueKey('nav-track-link-unlinked'),
            value: null,
            dense: true,
            title: Text('Leave unlinked'),
          ),
          for (final dive in candidates)
            RadioListTile<String?>(
              key: ValueKey('nav-track-link-${dive.id}'),
              value: dive.id,
              dense: true,
              title: Text(
                '${units.formatDate(dive.effectiveEntryTime)} '
                '${units.formatTime(dive.effectiveEntryTime)}',
              ),
            ),
        ],
      ),
    );
  }
}

class _WarningCard extends StatelessWidget {
  const _WarningCard({super.key, required this.text, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              Icons.warning_amber,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}
