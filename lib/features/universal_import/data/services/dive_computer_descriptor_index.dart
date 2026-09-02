import 'package:libdivecomputer_plugin/libdivecomputer_plugin.dart' as pigeon;

/// One libdivecomputer descriptor reduced to the three values
/// `DiveComputerHostApi.parseRawDiveData` needs.
class DiveComputerModel {
  final String vendor;
  final String product;

  /// libdivecomputer's model number. Several descriptors can share a
  /// `(vendor, product)` pair and differ only here; see
  /// [DiveComputerDescriptorIndex.resolve].
  final int model;

  const DiveComputerModel({
    required this.vendor,
    required this.product,
    required this.model,
  });

  @override
  String toString() => '$vendor $product (0x${model.toRadixString(16)})';

  @override
  bool operator ==(Object other) =>
      other is DiveComputerModel &&
      other.vendor == vendor &&
      other.product == product &&
      other.model == model;

  @override
  int get hashCode => Object.hash(vendor, product, model);
}

/// Resolves a free-text dive-computer name against libdivecomputer's own
/// descriptor list.
///
/// Importers receive the computer as whatever string the source app wrote:
/// MacDive's `ZDIVE.ZCOMPUTER` holds display names such as
/// "Shearwater Teric" or "Suunto EON Steel Black". libdivecomputer names the
/// same devices as a `(vendor, product)` pair, and the plugin exposes the
/// whole table through `DiveComputerHostApi.getDeviceDescriptors()`. Matching
/// against that table rather than a hand-maintained allowlist means every
/// model libdivecomputer supports is reachable, and the set grows on its own
/// whenever the vendored submodule advances (issue #1436).
///
/// Matching is deliberately narrow:
///
/// * Comparison ignores case and all whitespace, the same tolerance the
///   native BLE-name matcher applies (`strcasecmp_nospace` in
///   `libdc_wrapper.c`), so "Puck4" matches the product "Puck 4" and
///   "Aqua Lung" matches the vendor "Aqualung".
/// * A name is matched from its first token, one whole token at a time,
///   longest first. "Suunto EON Steel Black" therefore prefers the descriptor
///   of that exact name over the shorter "Suunto EON Steel".
/// * A name that matches nothing resolves to an empty list. Failing closed
///   matters because MacDive also stores names libdivecomputer has never
///   heard of ("Oceanic Matrix Master", "No Computer"), and feeding their
///   bytes to an arbitrary parser is worse than skipping them.
class DiveComputerDescriptorIndex {
  /// Normalised `"vendorproduct"` key to every descriptor sharing it, in the
  /// order libdivecomputer declared them.
  final Map<String, List<DiveComputerModel>> _byKey;

  const DiveComputerDescriptorIndex._(this._byKey);

  /// An index that resolves nothing. Used as the starting value before the
  /// platform channel has been consulted, and as the result when it reports
  /// no descriptors at all.
  const DiveComputerDescriptorIndex.empty()
    : _byKey = const <String, List<DiveComputerModel>>{};

  factory DiveComputerDescriptorIndex.fromDescriptors(
    List<pigeon.DeviceDescriptor> descriptors,
  ) {
    final byKey = <String, List<DiveComputerModel>>{};
    for (final d in descriptors) {
      final vendor = d.vendor.trim();
      final product = d.product.trim();
      if (vendor.isEmpty || product.isEmpty) continue;
      final key = normalize('$vendor $product');
      if (key.isEmpty) continue;
      byKey
          .putIfAbsent(key, () => <DiveComputerModel>[])
          .add(
            DiveComputerModel(vendor: vendor, product: product, model: d.model),
          );
    }
    return DiveComputerDescriptorIndex._(byKey);
  }

  /// True when there is nothing to match against, which on a real device
  /// means the descriptor list could not be read rather than that
  /// libdivecomputer supports no computers.
  bool get isEmpty => _byKey.isEmpty;

  /// Number of distinct `(vendor, product)` names known. Models that differ
  /// only by number count once.
  int get length => _byKey.length;

  /// Every descriptor matching [name], or an empty list when none does.
  ///
  /// More than one is returned only for the handful of `(vendor, product)`
  /// pairs libdivecomputer declares twice (Oceanic OC1, Suunto Zoop Novo,
  /// Uwatec Aladin 2G and four more). Those duplicates always sit inside one
  /// family, so the parser they select is the same either way, but the model
  /// number reaches the parser and can steer header layout. Callers should
  /// try them in order rather than assume the first is right.
  List<DiveComputerModel> resolve(String? name) {
    if (name == null) return const [];
    final tokens = name
        .trim()
        .split(RegExp(r'\s+'))
        .map(normalize)
        .where((t) => t.isNotEmpty)
        .toList();
    // A descriptor key always spans at least a vendor and a product, so a
    // one-token prefix can never match; starting at the full name and
    // shrinking gives longest-match-wins for free.
    for (var take = tokens.length; take >= 2; take--) {
      final match = _byKey[tokens.take(take).join()];
      if (match != null) return match;
    }
    return const [];
  }

  /// Lowercases and strips whitespace, so that spacing differences between
  /// how an app displays a model and how libdivecomputer spells it do not
  /// prevent a match.
  static String normalize(String value) =>
      value.replaceAll(RegExp(r'\s+'), '').toLowerCase();
}
