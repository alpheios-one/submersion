import 'package:flutter_test/flutter_test.dart';
import 'package:libdivecomputer_plugin/libdivecomputer_plugin.dart' as pigeon;
import 'package:submersion/features/universal_import/data/services/dive_computer_descriptor_index.dart';

pigeon.DeviceDescriptor _d(String vendor, String product, int model) =>
    pigeon.DeviceDescriptor(
      vendor: vendor,
      product: product,
      model: model,
      transports: const [pigeon.TransportType.ble],
    );

/// A slice of libdivecomputer's `g_descriptors[]` chosen to cover the shapes
/// the matcher has to handle: a plain name, two names where one is a prefix of
/// the other, a product libdivecomputer spells with a space that vendors write
/// without, and a `(vendor, product)` pair declared more than once.
final _descriptors = <pigeon.DeviceDescriptor>[
  _d('Shearwater', 'Teric', 8),
  _d('Shearwater', 'Tern', 12),
  _d('Suunto', 'EON Steel', 0),
  _d('Suunto', 'EON Steel Black', 3),
  _d('Suunto', 'D5', 2),
  _d('Suunto', 'Zoop Novo', 0x1E),
  _d('Suunto', 'Zoop Novo', 0x1F),
  _d('Mares', 'Puck 4', 0x35),
  _d('Aqualung', 'i200C', 0x4649),
  _d('Aqualung', 'i200C', 0x4749),
  _d('Oceanic', 'Geo 4.0', 0x4653),
];

void main() {
  group('DiveComputerDescriptorIndex', () {
    final index = DiveComputerDescriptorIndex.fromDescriptors(_descriptors);

    test('resolves a "Vendor Product" display name', () {
      expect(index.resolve('Shearwater Teric'), [
        const DiveComputerModel(
          vendor: 'Shearwater',
          product: 'Teric',
          model: 8,
        ),
      ]);
    });

    test('is case and whitespace insensitive', () {
      // MacDive, Shearwater Cloud and BLE advertisements all spell the same
      // device slightly differently; libdivecomputer's own name matcher
      // ignores case and spaces for exactly this reason.
      for (final name in [
        'MARES PUCK 4',
        'mares puck4',
        'Mares  Puck 4',
        ' Mares Puck4 ',
      ]) {
        expect(
          index.resolve(name).single.product,
          'Puck 4',
          reason: 'should match "$name"',
        );
      }
    });

    test('prefers the longest matching name', () {
      // "Suunto EON Steel" is a prefix of "Suunto EON Steel Black". Matching
      // the shorter one would hand the bytes to a different model number.
      expect(
        index.resolve('Suunto EON Steel Black').single.product,
        'EON Steel Black',
      );
      expect(index.resolve('Suunto EON Steel').single.product, 'EON Steel');
    });

    test('matches only on whole tokens', () {
      // "Tern" must not be found inside "Ternary": a prefix match that ignored
      // token boundaries would resolve names that share only a few letters.
      expect(index.resolve('Shearwater Ternary'), isEmpty);
    });

    test('returns every model sharing one name, in declaration order', () {
      // libdivecomputer declares seven (vendor, product) pairs twice. The
      // parser they select is the same, but the model number reaches it, so
      // the caller has to be able to try each.
      expect(index.resolve('Suunto Zoop Novo').map((m) => m.model), [
        0x1E,
        0x1F,
      ]);
      expect(index.resolve('Aqualung i200C').map((m) => m.model), [
        0x4649,
        0x4749,
      ]);
    });

    test('fails closed on a name libdivecomputer does not know', () {
      // Real MacDive values. "Oceanic Matrix Master" has a real vendor but no
      // such product; the others are not computers at all. Resolving any of
      // them would send raw bytes to an arbitrary parser.
      for (final name in [
        'Oceanic Matrix Master',
        'No Computer',
        'Some Unknown Thing',
        'Teric',
        'Shearwater',
        '',
        '   ',
      ]) {
        expect(
          index.resolve(name),
          isEmpty,
          reason: 'should not match "$name"',
        );
      }
      expect(index.resolve(null), isEmpty);
    });

    test('falls back to the longest known prefix of a decorated name', () {
      // Source apps decorate names ("... (Bluetooth)", a variant suffix).
      // Dropping to the longest known prefix keeps those decodable, and the
      // prefix still pins the vendor and nearly all of the product, so the
      // parser it selects is the right family. RawProfileSanityCheck is what
      // catches the case where it was not.
      expect(
        index.resolve('Oceanic Geo 4.0 Titanium').single.product,
        'Geo 4.0',
      );
      expect(
        index.resolve('Shearwater Teric (Bluetooth)').single.product,
        'Teric',
      );
    });

    test('empty descriptor list resolves nothing and reports itself empty', () {
      final empty = DiveComputerDescriptorIndex.fromDescriptors(const []);
      expect(empty.isEmpty, isTrue);
      expect(empty.resolve('Shearwater Teric'), isEmpty);
      expect(const DiveComputerDescriptorIndex.empty().isEmpty, isTrue);
    });

    test('DiveComputerModel compares by value', () {
      // Callers hold these in lists and compare them; identity equality would
      // make "did we already try this model" quietly wrong.
      const a = DiveComputerModel(
        vendor: 'Suunto',
        product: 'Zoop Novo',
        model: 0x1E,
      );
      const b = DiveComputerModel(
        vendor: 'Suunto',
        product: 'Zoop Novo',
        model: 0x1E,
      );
      const differentModel = DiveComputerModel(
        vendor: 'Suunto',
        product: 'Zoop Novo',
        model: 0x1F,
      );
      const differentProduct = DiveComputerModel(
        vendor: 'Suunto',
        product: 'D5',
        model: 0x1E,
      );
      const differentVendor = DiveComputerModel(
        vendor: 'Mares',
        product: 'Zoop Novo',
        model: 0x1E,
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(differentModel));
      expect(a, isNot(differentProduct));
      expect(a, isNot(differentVendor));
      expect(a, isNot('Suunto Zoop Novo'));
      // The model number is hex everywhere else it appears (descriptor.c, the
      // docs), so a decimal toString would be needless friction when reading a
      // failure.
      expect(a.toString(), 'Suunto Zoop Novo (0x1e)');
    });

    test('skips descriptors with a blank vendor or product', () {
      final index = DiveComputerDescriptorIndex.fromDescriptors([
        _d('', 'Teric', 1),
        _d('Shearwater', '  ', 2),
        _d('Shearwater', 'Teric', 3),
      ]);
      expect(index.length, 1);
      expect(index.resolve('Shearwater Teric').single.model, 3);
    });
  });
}
