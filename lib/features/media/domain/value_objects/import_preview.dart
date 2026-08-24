import 'package:equatable/equatable.dart';

/// Where the pre-import review finds the art for one candidate row.
///
/// The review page is shared by three import paths that resolve bytes
/// through two entirely different stacks: the device gallery goes through
/// photo_manager by asset id, while pasted URLs and manifest entries go
/// through the HTTP cache by URL. Without this the page would have to know
/// both, so the candidate carries a handle and the thumbnail widget does
/// the resolving.
///
/// A sealed hierarchy rather than two nullable strings, matching
/// [MediaAttachTarget]: a candidate is a gallery asset or a remote URL,
/// never both, and `switch` over it is exhaustive so a third import path
/// cannot quietly render a blank row.
sealed class ImportPreview extends Equatable {
  const ImportPreview();

  @override
  bool get stringify => true;
}

/// An asset in the device photo library, addressed by its platform id.
final class AssetImportPreview extends ImportPreview {
  const AssetImportPreview(this.assetId);

  final String assetId;

  @override
  List<Object?> get props => [assetId];
}

/// A remote image, addressed by its URL. Covers both pasted URLs and
/// manifest entries, which resolve identically.
final class UrlImportPreview extends ImportPreview {
  const UrlImportPreview(this.url);

  final String url;

  @override
  List<Object?> get props => [url];
}
