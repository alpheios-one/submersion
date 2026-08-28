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
/// Nothing caps the name a diver can type, so both free-text fields shrink
/// to hold the URL under the cap: the description first, then the common
/// name. The scientific name identifies the species and is never cut.
Uri buildSpeciesSuggestionUrl({
  required Species species,
  required String locale,
  required String appVersion,
}) {
  var description = species.description ?? '';
  var commonName = species.commonName;
  Uri build() =>
      Uri.https('github.com', '/$speciesSuggestionRepository/issues/new', {
        'title': 'Species suggestion: $commonName',
        'labels': speciesSuggestionLabel,
        'body': _body(species, commonName, description, locale, appVersion),
      });

  /// How much to cut for a URL [over] characters too long. Encoded
  /// characters can be three bytes each, so cut generously.
  int cutFor(int over, int available) => (over ~/ 3 + 1).clamp(1, available);

  var uri = build();
  while (uri.toString().length > speciesSuggestionMaxUrlLength &&
      description.isNotEmpty) {
    final over = uri.toString().length - speciesSuggestionMaxUrlLength;
    description = description.substring(
      0,
      description.length - cutFor(over, description.length),
    );
    uri = build();
  }
  // The name appears in both the title and the body, so it is the only
  // field left that can still carry the URL over the cap.
  while (uri.toString().length > speciesSuggestionMaxUrlLength &&
      commonName.length > 1) {
    final over = uri.toString().length - speciesSuggestionMaxUrlLength;
    commonName = commonName.substring(
      0,
      commonName.length - cutFor(over, commonName.length - 1),
    );
    uri = build();
  }
  return uri;
}

String _body(
  Species species,
  String commonName,
  String description,
  String locale,
  String appVersion,
) {
  final json = const JsonEncoder.withIndent('  ').convert({
    'commonName': commonName,
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
