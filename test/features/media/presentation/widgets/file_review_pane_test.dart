import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/features/media/domain/value_objects/extracted_file.dart';
import 'package:submersion/features/media/domain/value_objects/matched_selection.dart';
import 'package:submersion/features/media/domain/value_objects/media_source_metadata.dart';
import 'package:submersion/features/media/presentation/providers/files_tab_providers.dart';
import 'package:submersion/features/media/presentation/widgets/capture_time_offset_bar.dart';
import 'package:submersion/features/media/presentation/widgets/file_review_pane.dart';

import '../../../../helpers/test_app.dart';

ExtractedFile _ef(String path) => ExtractedFile(
  sourcePath: path,
  file: File(path),
  metadata: MediaSourceMetadata(
    takenAt: DateTime.utc(2024, 4, 1),
    mimeType: 'image/jpeg',
  ),
);

FilesTabState _staged() => FilesTabState.initial().copyWith(
  files: [_ef('/a.jpg'), _ef('/b.jpg'), _ef('/c.jpg')],
  match: MatchedSelection(
    matched: {
      'd1': [_ef('/a.jpg'), _ef('/b.jpg')],
    },
    unmatched: [_ef('/c.jpg')],
  ),
);

Future<void> _pumpPane(
  WidgetTester tester,
  FilesTabState state, {
  bool flat = false,
}) async {
  await tester.pumpWidget(
    testApp(
      locale: const Locale('en'),
      child: FileReviewPane(state: state, flat: flat),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('summary shows file/dive/unmatched counts', (tester) async {
    await _pumpPane(tester, _staged());

    // "files", not "photos": the tab admits video too.
    expect(find.textContaining('3 files'), findsOneWidget);
    expect(find.textContaining('1 dive'), findsOneWidget);
    expect(find.textContaining('1 unmatched'), findsOneWidget);
  });

  testWidgets('the offset bar is shown while files are staged', (tester) async {
    await _pumpPane(tester, _staged());

    expect(find.byType(CaptureTimeOffsetBar), findsOneWidget);
  });

  testWidgets('the offset bar stays visible once everything matched', (
    tester,
  ) async {
    // Gating the bar on unmatched.isNotEmpty would hide it here, stranding a
    // user who shifted too far with no way back.
    final state = FilesTabState.initial().copyWith(
      files: [_ef('/a.jpg')],
      match: MatchedSelection(
        matched: {
          'd1': [_ef('/a.jpg')],
        },
        unmatched: const [],
      ),
    );

    await _pumpPane(tester, state);

    expect(find.byType(CaptureTimeOffsetBar), findsOneWidget);
  });

  testWidgets('the offset bar is hidden when auto-match is off', (
    tester,
  ) async {
    await _pumpPane(tester, _staged().copyWith(autoMatchByDate: false));

    expect(find.byType(CaptureTimeOffsetBar), findsNothing);
  });

  testWidgets('the offset bar is hidden with no staged files', (tester) async {
    await _pumpPane(tester, FilesTabState.initial());

    expect(find.byType(CaptureTimeOffsetBar), findsNothing);
  });

  testWidgets('the offset bar is hidden in a site session', (tester) async {
    // A site owns every picked file, so there is no matching to correct.
    await _pumpPane(tester, _staged(), flat: true);

    expect(find.byType(CaptureTimeOffsetBar), findsNothing);
  });
}
