import 'dart:convert';

import 'package:submersion/features/marine_life/domain/entities/species.dart';

/// Where suggestions land: a prefilled new-issue page in the project's
/// GitHub repository. The app sends nothing itself; the diver posts the
/// issue from their own account in the browser.
const String speciesSuggestionRepository = 'submersion-app/submersion';
const String speciesSuggestionLabel = 'species-suggestion';

/// Browsers and GitHub both accept URLs comfortably below this.
const int speciesSuggestionMaxUrlLength = 8000;

/// Builds the prefilled issue URL for [species]. The body carries a JSON
/// block a maintainer (or a script) can lift straight into the catalog.
/// The description is the only free-text field and is truncated first when
/// the URL would exceed the cap.
Uri buildSpeciesSuggestionUrl({
  required Species species,
  required String locale,
  required String appVersion,
}) {
  var description = species.description ?? '';
  Uri build() =>
      Uri.https('github.com', '/$speciesSuggestionRepository/issues/new', {
        'title': 'Species suggestion: ${species.commonName}',
        'labels': speciesSuggestionLabel,
        'body': _body(species, description, locale, appVersion),
      });

  var uri = build();
  while (uri.toString().length > speciesSuggestionMaxUrlLength &&
      description.isNotEmpty) {
    final over = uri.toString().length - speciesSuggestionMaxUrlLength;
    // Encoded characters can be three bytes each; cut generously.
    final cut = (over ~/ 3 + 1).clamp(1, description.length);
    description = description.substring(0, description.length - cut);
    uri = build();
  }
  return uri;
}

String _body(
  Species species,
  String description,
  String locale,
  String appVersion,
) {
  final json = const JsonEncoder.withIndent('  ').convert({
    'commonName': species.commonName,
    'scientificName': species.scientificName,
    'category': species.category.name,
    'taxonomyClass': species.taxonomyClass,
    'description': description,
    'locale': locale,
    'appVersion': appVersion,
  });
  return 'Please consider adding this species to the bundled catalog.\n\n'
      '```json\n$json\n```\n';
}
