import 'package:submersion/features/nav_track/data/services/parsers/parsed_nav_track.dart';

/// The diver-facing text for a failed route import.
///
/// [NavTrackParseException.message] names the offending row or value in
/// English, for the log and for tests. This is the localizable half:
/// today it returns plain English (no l10n keys exist yet for this feature),
/// but every caller already goes through this one function, so a later l10n
/// pass only has to change what happens inside it -- mirrors
/// `trackParseErrorText` for the GPS logger.
String navTrackParseErrorText(NavTrackParseException e) {
  return switch (e.reason) {
    NavTrackParseReason.unsupportedFormat =>
      'This file is not a Seacraft ENC navigation log.',
    NavTrackParseReason.unreadable =>
      'This file could not be read as a Seacraft ENC navigation log.',
    NavTrackParseReason.tooShort =>
      'This recording has too few samples to be a usable route.',
    NavTrackParseReason.badData =>
      'This file has data Submersion could not make sense of.',
    NavTrackParseReason.tooLarge =>
      'This recording has more samples than a route can store.',
  };
}
