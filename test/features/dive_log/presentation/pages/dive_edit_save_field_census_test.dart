import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level drift guard for issue #1392.
///
/// `DiveEditPage._saveDive` builds a fresh `Dive(...)` and
/// `DiveRepository.updateDive` writes every column it reads off that entity.
/// Any `Dive` field the writer reads but the form literal never names is
/// therefore reset to the entity default on every save. The widget test in
/// `dive_edit_preserves_hidden_fields_test.dart` proves the fields known today
/// survive; this test makes the next field added to the entity and the writer,
/// but not to the form, fail here instead of silently wiping data.
void main() {
  const entityPath = 'lib/features/dive_log/domain/entities/dive.dart';
  const repositoryPath =
      'lib/features/dive_log/data/repositories/dive_repository_impl.dart';
  const editPagePath =
      'lib/features/dive_log/presentation/pages/dive_edit_page.dart';

  /// Fields `updateDive` reads that the form is allowed to leave unnamed.
  /// Every entry needs a reason: either the value reaches the row another way
  /// or dropping it is the intended migration.
  const allowed = <String, String>{
    'tripId': 'updateDive falls back to dive.trip?.id, which the form names',
    'weightAmount':
        'legacy single weight; the form migrates it into weights on load '
        'and saves that list, so the legacy column is retired on purpose',
    'weightType':
        'legacy single weight type; retired together with weightAmount',
  };

  String between(String source, String start, String end, String what) {
    final from = source.indexOf(start);
    expect(from, greaterThanOrEqualTo(0), reason: 'could not find $what');
    final to = source.indexOf(end, from + start.length);
    expect(to, greaterThan(from), reason: 'could not find the end of $what');
    return source.substring(from, to);
  }

  test('every Dive field updateDive writes is named by _saveDive', () {
    final entity = File(entityPath).readAsStringSync();
    final repository = File(repositoryPath).readAsStringSync();
    final editPage = File(editPagePath).readAsStringSync();

    final constructor = between(
      entity,
      '  const Dive({',
      '\n  });',
      'the Dive constructor',
    );
    final ctorParams = RegExp(
      r'this\.(\w+)',
    ).allMatches(constructor).map((m) => m.group(1)!).toSet();

    final writer = between(
      repository,
      'Future<void> updateDive(domain.Dive dive) async {',
      '_syncRepository.markRecordPending(',
      'the updateDive companion write',
    );
    final written = RegExp(
      r'\bdive\.(\w+)',
    ).allMatches(writer).map((m) => m.group(1)!).toSet();

    final saveMethod = between(
      editPage,
      'Future<void> _saveDive(',
      'ref.read(paginatedDiveListProvider.notifier)',
      '_saveDive',
    );
    final literal = between(
      saveMethod,
      'final dive = Dive(',
      '\n      );',
      'the Dive literal in _saveDive',
    );
    final named = RegExp(
      r'^\s+(\w+):',
      multiLine: true,
    ).allMatches(literal).map((m) => m.group(1)!).toSet();

    // Guard the parsers themselves: a moved marker must not pass vacuously.
    expect(ctorParams.length, greaterThan(60));
    expect(written.intersection(ctorParams).length, greaterThan(50));
    expect(named.length, greaterThan(50));

    final unnamed =
        written
            .intersection(ctorParams)
            .difference(named)
            .difference(allowed.keys.toSet())
            .toList()
          ..sort();

    expect(
      unnamed,
      isEmpty,
      reason:
          'updateDive writes these Dive fields but _saveDive never names '
          'them, so every save resets them to the entity default. Carry '
          'each one through from _existingDive, or add it to the allow '
          'list in this test with a reason: $unnamed',
    );

    // The allow list must not outlive its entries.
    for (final field in allowed.keys) {
      expect(
        written.contains(field) && !named.contains(field),
        isTrue,
        reason:
            '$field is on the allow list but is no longer an unnamed field '
            'updateDive writes; remove it',
      );
    }
  });
}
