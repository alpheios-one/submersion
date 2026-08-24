/// One thing the user is about to import, before any row exists for it.
class ImportCandidate {
  const ImportCandidate({
    required this.key,
    required this.title,
    this.takenAt,
    this.error,
  });

  /// Caller-defined identity (asset id, URL, manifest entry key).
  final String key;
  final String title;

  /// Capture timestamp as wall-clock UTC; null when unknown.
  final DateTime? takenAt;

  /// Why the candidate could not be examined (a failed fetch). Such a
  /// candidate can still be imported against an explicit target.
  final String? error;
}

/// What confirming did, for the result snackbar.
class ImportReviewResult {
  const ImportReviewResult({
    required this.linked,
    required this.skipped,
    this.failures = const {},
  });

  final int linked;
  final int skipped;
  final Map<String, String> failures;
}
