/// The language reverse-geocoded place names are stored in.
///
/// A synced per-diver setting (issue #1187). Stored as the ISO 639-1 code,
/// never as a display name. English is the default because every row
/// written before the setting existed was geocoded in English (issue #214),
/// and mixing languages within one logbook splits a country across two
/// statistics buckets. There is deliberately no "follow app language"
/// value: the app language can be `system`, which resolves per device.
abstract final class PlaceNameLanguage {
  static const String defaultCode = 'en';

  /// The app's own languages, in the order the language picker lists them.
  static const List<String> supportedCodes = [
    'en',
    'es',
    'fr',
    'de',
    'it',
    'nl',
    'pt',
    'hu',
    'ar',
    'he',
    'zh',
  ];

  /// A supported code, or [defaultCode] for anything else. A synced peer on a
  /// newer build could send a code this build does not know.
  static String normalize(String? code) =>
      code != null && supportedCodes.contains(code) ? code : defaultCode;
}
