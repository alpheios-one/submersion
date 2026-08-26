import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/certifications/domain/entities/certification.dart';
import 'package:submersion/features/certifications/presentation/providers/certification_providers.dart';
import 'package:submersion/features/certifications/presentation/widgets/certification_picker.dart';

import '../../../../helpers/test_app.dart';

class _MockCertListNotifier
    extends StateNotifier<AsyncValue<List<Certification>>>
    implements CertificationListNotifier {
  _MockCertListNotifier(List<Certification> certs)
    : super(AsyncValue.data(certs));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final _now = DateTime(2026, 8, 24);

Certification _makeCert({
  required String name,
  CertificationLevel? level,
  DateTime? issueDate,
  CertificationAgency agency = CertificationAgency.padi,
}) {
  return Certification(
    id: 'c1',
    name: name,
    agency: agency,
    level: level,
    issueDate: issueDate,
    createdAt: _now,
    updatedAt: _now,
  );
}

/// The collapsed picker field, which shows the current selection.
Future<void> _pumpField(WidgetTester tester, Certification? selected) async {
  await tester.pumpWidget(
    testApp(
      locale: const Locale('en'),
      overrides: [
        certificationListNotifierProvider.overrideWith(
          (ref) => _MockCertListNotifier(const []),
        ),
      ],
      child: CertificationPicker(
        selectedCertification: selected,
        onCertificationSelected: (_) {},
      ),
    ),
  );
  await tester.pump();
}

/// The sheet body directly, rather than through showModalBottomSheet: it is a
/// public widget, so rendering it avoids driving a modal route just to read
/// two lines of text off a tile.
Future<void> _pumpSheet(WidgetTester tester, List<Certification> certs) async {
  await tester.pumpWidget(
    testApp(
      locale: const Locale('en'),
      overrides: [
        certificationListNotifierProvider.overrideWith(
          (ref) => _MockCertListNotifier(certs),
        ),
      ],
      child: CertificationPickerSheet(
        scrollController: ScrollController(),
        selectedCertification: null,
        onCertificationSelected: (_) {},
      ),
    ),
  );
  await tester.pump();
}

String _subtitleOf(WidgetTester tester, Finder tile) =>
    ((tester.widget<ListTile>(tile)).subtitle! as Text).data!;

/// The label the sheet's [Semantics] wrapper declares for a tile.
///
/// Read off the widget rather than queried with `find.bySemanticsLabel`,
/// following the precedent in certification_ecard_test.dart: this wrapper
/// merges with the tile's own text instead of replacing it, so the rendered
/// node is the declared label followed by the visible title and subtitle.
String _tileSemanticsLabel(WidgetTester tester) {
  final candidates = find.ancestor(
    of: find.byType(ListTile),
    matching: find.byType(Semantics),
  );
  for (final element in candidates.evaluate()) {
    final label = (element.widget as Semantics).properties.label;
    if (label != null && label.isNotEmpty) return label;
  }
  return '';
}

void main() {
  // The sheet subtitle dates itself with DateFormat.yMMMd(), which resolves
  // against Intl.defaultLocale (a process global) rather than the
  // MaterialApp.locale the harness passes. Pin it so the "Aug 24, 2026"
  // assertion states its real dependency, and restore it afterwards because
  // the global leaks across tests in the same isolate.
  String? previousLocale;
  setUp(() {
    previousLocale = Intl.defaultLocale;
    Intl.defaultLocale = 'en';
  });
  tearDown(() => Intl.defaultLocale = previousLocale);

  group('collapsed picker field', () {
    testWidgets('a custom name keeps the certification in the subtitle', (
      tester,
    ) async {
      // Issue #1265: the title is the custom name, so the subtitle is the only
      // place left for the level.
      await _pumpField(
        tester,
        _makeCert(name: 'Bill Ansell', level: CertificationLevel.diveMaster),
      );

      expect(find.text('Bill Ansell'), findsOneWidget);
      expect(_subtitleOf(tester, find.byType(ListTile)), 'PADI - Divemaster');
    });

    testWidgets('a derived title does not repeat the level', (tester) async {
      await _pumpField(
        tester,
        _makeCert(name: '', level: CertificationLevel.diveMaster),
      );

      expect(find.text('Divemaster'), findsOneWidget);
      expect(_subtitleOf(tester, find.byType(ListTile)), 'PADI');
    });
  });

  group('picker sheet', () {
    testWidgets('a custom name keeps the certification in the subtitle', (
      tester,
    ) async {
      await _pumpSheet(tester, [
        _makeCert(
          name: 'Bill Ansell',
          level: CertificationLevel.diveMaster,
          issueDate: DateTime(2026, 8, 24),
        ),
      ]);

      expect(
        _subtitleOf(tester, find.byType(ListTile)),
        'PADI - Divemaster - Aug 24, 2026',
      );
    });

    testWidgets('a certification with no issue date omits the date', (
      tester,
    ) async {
      await _pumpSheet(tester, [
        _makeCert(name: 'Bill Ansell', level: CertificationLevel.diveMaster),
      ]);

      expect(_subtitleOf(tester, find.byType(ListTile)), 'PADI - Divemaster');
    });

    testWidgets('the accessibility label names the certification too', (
      tester,
    ) async {
      await _pumpSheet(tester, [
        _makeCert(name: 'Bill Ansell', level: CertificationLevel.diveMaster),
      ]);

      // A screen reader must hear the level even when a custom name owns the
      // title, since the title alone no longer carries it.
      expect(_tileSemanticsLabel(tester), 'PADI Bill Ansell, Divemaster');
    });

    testWidgets('a derived title does not repeat the level', (tester) async {
      await _pumpSheet(tester, [
        _makeCert(name: '', level: CertificationLevel.diveMaster),
      ]);

      expect(_subtitleOf(tester, find.byType(ListTile)), 'PADI');
      // The title is already the level, so the label says it once, not twice.
      expect(_tileSemanticsLabel(tester), 'PADI Divemaster');
    });
  });
}
