/// The strand a `dive_data_sources` row belongs to for display purposes.
///
/// A dive can hold more provenance rows than it has sources to show. Combine
/// carries every segment's row onto the merged dive because each one holds the
/// only surviving copy of its half's rawData/rawFingerprint/sourceUuid, which
/// reparse and the import duplicate checker read directly (issue #1451). Those
/// rows collapse on read instead: rows sharing a strand key are one chip, and
/// the first of them wins.
///
/// The key is total, so every row has one:
///
/// - `computerId` when the row has one. It wins over the slot: a carried row
///   still belongs to its computer's strand, and collapsing on it keeps a
///   merged dive's rows in one chip with any later same-computer source.
/// - else `mergeSourceSlot`, the row's position among its own segment's
///   strands, stamped by [DiveMergeService.apply]. This is what collapses the
///   halves of a file or cloud import, which carry no computer.
/// - else the row's own id, which is unique, so such a row is always its own
///   strand and never collapses against anything.
///
/// Namespaced per kind so a computer id can never be mistaken for a slot.
/// Mirrored in SQL by `DiveRepository.hasMultipleDataSources`; keep the two in
/// step.
String dataSourceStrandKey({
  required String rowId,
  required String? computerId,
  required int? mergeSourceSlot,
}) => switch ((computerId, mergeSourceSlot)) {
  (final String id, _) => 'computer:$id',
  (null, final int slot) => 'mergeSlot:$slot',
  (null, null) => 'row:$rowId',
};
