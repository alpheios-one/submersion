import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/features/dashboard/presentation/providers/gauge_providers.dart';
import 'package:submersion/features/equipment/domain/entities/equipment_item.dart';
import 'package:submersion/features/equipment/domain/entities/service_clock_status.dart';
import 'package:submersion/features/equipment/domain/entities/service_kind.dart';
import 'package:submersion/features/equipment/domain/entities/service_schedule.dart';
import 'package:submersion/features/equipment/presentation/providers/equipment_providers.dart';

final _t0 = DateTime(2026, 1, 1);
final _now = DateTime(2026, 7, 24);

EquipmentItem _item(String name, EquipmentType type) =>
    EquipmentItem(id: name, name: name, type: type);

ServiceClockStatus _status(
  ServiceClockSeverity severity, {
  DateTime? dueDate,
}) => ServiceClockStatus(
  schedule: ServiceSchedule(
    id: 'schedule',
    equipmentId: 'equipment',
    serviceKindId: 'kind',
    createdAt: _t0,
    updatedAt: _t0,
  ),
  kind: ServiceKind(
    id: 'kind',
    name: 'Annual service',
    createdAt: _t0,
    updatedAt: _t0,
  ),
  anchor: _t0,
  dueDate: dueDate,
  severity: severity,
  now: _now,
);

EquipmentClocks _clocks(
  EquipmentItem item,
  List<ServiceClockStatus> statuses,
) => (item: item, statuses: statuses);

void main() {
  group('worstGaugePerType', () {
    test('keeps the worst severity per equipment type', () {
      final result = worstGaugePerType([
        _clocks(_item('Reg A', EquipmentType.regulator), [
          _status(ServiceClockSeverity.ok),
        ]),
        _clocks(_item('Reg B', EquipmentType.regulator), [
          _status(ServiceClockSeverity.overdue, dueDate: DateTime(2026, 6, 1)),
        ]),
        _clocks(_item('BCD', EquipmentType.bcd), [
          _status(ServiceClockSeverity.dueSoon, dueDate: DateTime(2026, 8, 14)),
        ]),
      ]);
      expect(result, hasLength(2));
      final reg = result.firstWhere((g) => g.type == EquipmentType.regulator);
      expect(reg.status.severity, ServiceClockSeverity.overdue);
      expect(reg.itemName, 'Reg B');
      final bcd = result.firstWhere((g) => g.type == EquipmentType.bcd);
      expect(bcd.status.severity, ServiceClockSeverity.dueSoon);
    });

    test('tie on severity resolved by earlier dueDate', () {
      final result = worstGaugePerType([
        _clocks(_item('BCD later', EquipmentType.bcd), [
          _status(ServiceClockSeverity.dueSoon, dueDate: DateTime(2026, 9, 1)),
        ]),
        _clocks(_item('BCD sooner', EquipmentType.bcd), [
          _status(ServiceClockSeverity.dueSoon, dueDate: DateTime(2026, 8, 1)),
        ]),
      ]);
      expect(result.single.itemName, 'BCD sooner');
    });

    test('null dueDate loses severity ties to a dated clock', () {
      final result = worstGaugePerType([
        _clocks(_item('Undated', EquipmentType.computer), [
          _status(ServiceClockSeverity.dueSoon),
        ]),
        _clocks(_item('Dated', EquipmentType.computer), [
          _status(ServiceClockSeverity.dueSoon, dueDate: DateTime(2026, 8, 1)),
        ]),
      ]);
      expect(result.single.itemName, 'Dated');
    });

    test('empty input yields empty output', () {
      expect(worstGaugePerType([]), isEmpty);
    });

    test('carries the winning item id so the chip can deep-link', () {
      // Id and name deliberately differ: the chip labels with the name but
      // must route with the id.
      final result = worstGaugePerType([
        _clocks(
          const EquipmentItem(
            id: 'reg-b-id',
            name: 'Reg B',
            type: EquipmentType.regulator,
          ),
          [
            _status(
              ServiceClockSeverity.overdue,
              dueDate: DateTime(2026, 6, 1),
            ),
          ],
        ),
      ]);
      expect(result.single.itemId, 'reg-b-id');
      expect(result.single.itemName, 'Reg B');
    });

    test('a dated clock beats an undated one when tied on severity', () {
      // The first-seen item is undated; the dated candidate must replace it,
      // exercising the null-dueDate tie-break branch.
      final result = worstGaugePerType([
        _clocks(_item('Undated', EquipmentType.regulator), [
          _status(ServiceClockSeverity.dueSoon),
        ]),
        _clocks(_item('Dated', EquipmentType.regulator), [
          _status(ServiceClockSeverity.dueSoon, dueDate: DateTime(2026, 8, 1)),
        ]),
      ]);
      expect(result.single.itemName, 'Dated');
    });
  });

  group('dueGearGauges', () {
    test('null due dates sort after dated clocks of equal severity', () {
      final result = dueGearGauges([
        _clocks(_item('Undated', EquipmentType.regulator), [
          _status(ServiceClockSeverity.dueSoon),
        ]),
        _clocks(_item('Dated', EquipmentType.bcd), [
          _status(ServiceClockSeverity.dueSoon, dueDate: DateTime(2026, 8, 1)),
        ]),
      ]);
      expect(result.gauges.map((g) => g.itemName), ['Dated', 'Undated']);
    });

    test('dated clocks sort first whichever side they start on', () {
      // Mirrors the case above with the inputs swapped, so the comparator is
      // exercised from both directions rather than only one.
      final result = dueGearGauges([
        _clocks(_item('Dated', EquipmentType.bcd), [
          _status(ServiceClockSeverity.dueSoon, dueDate: DateTime(2026, 8, 1)),
        ]),
        _clocks(_item('Undated', EquipmentType.regulator), [
          _status(ServiceClockSeverity.dueSoon),
        ]),
      ]);
      expect(result.gauges.map((g) => g.itemName), ['Dated', 'Undated']);
    });

    test('drops types whose worst clock is ok', () {
      final result = dueGearGauges([
        _clocks(_item('Reg', EquipmentType.regulator), [
          _status(ServiceClockSeverity.ok),
        ]),
        _clocks(_item('BCD', EquipmentType.bcd), [
          _status(ServiceClockSeverity.dueSoon, dueDate: DateTime(2026, 8, 1)),
        ]),
      ]);
      expect(result.gauges.map((g) => g.itemName), ['BCD']);
    });

    test('sorts overdue before due-soon, then earliest due date', () {
      final result = dueGearGauges([
        _clocks(_item('Soon-late', EquipmentType.bcd), [
          _status(ServiceClockSeverity.dueSoon, dueDate: DateTime(2026, 9, 1)),
        ]),
        _clocks(_item('Overdue', EquipmentType.regulator), [
          _status(ServiceClockSeverity.overdue, dueDate: DateTime(2026, 6, 1)),
        ]),
        _clocks(_item('Soon-early', EquipmentType.computer), [
          _status(ServiceClockSeverity.dueSoon, dueDate: DateTime(2026, 8, 1)),
        ]),
      ]);
      expect(result.gauges.map((g) => g.itemName), [
        'Overdue',
        'Soon-early',
        'Soon-late',
      ]);
    });

    test('caps the list', () {
      final types = [
        EquipmentType.regulator,
        EquipmentType.bcd,
        EquipmentType.computer,
        EquipmentType.transmitter,
        EquipmentType.drysuit,
        EquipmentType.wetsuit,
        EquipmentType.light,
        EquipmentType.camera,
      ];
      final result = dueGearGauges([
        for (var i = 0; i < types.length; i++)
          _clocks(_item('Item $i', types[i]), [
            _status(
              ServiceClockSeverity.dueSoon,
              dueDate: DateTime(2026, 8, 1 + i),
            ),
          ]),
      ]);
      expect(result.gauges, hasLength(6));
      expect(result.gauges.first.itemName, 'Item 0');
    });

    test('all-ok gear yields empty list', () {
      final result = dueGearGauges([
        _clocks(_item('Reg', EquipmentType.regulator), [
          _status(ServiceClockSeverity.ok),
        ]),
      ]);
      expect(result.gauges, isEmpty);
      expect(result.overdueOverflow, 0);
    });

    test('lists every overdue item, not just the worst of its type', () {
      // Four lapsed regulators are four things the diver has to service.
      // Collapsing them per type would name one and silently drop three.
      final result = dueGearGauges([
        for (var i = 0; i < 4; i++)
          _clocks(_item('Reg $i', EquipmentType.regulator), [
            _status(
              ServiceClockSeverity.overdue,
              dueDate: DateTime(2026, 6, 1 + i),
            ),
          ]),
      ]);
      expect(result.gauges.map((g) => g.itemName), [
        'Reg 0',
        'Reg 1',
        'Reg 2',
        'Reg 3',
      ]);
      expect(result.overdueOverflow, 0);
    });

    test('due-soon clocks still collapse to the worst per type', () {
      final result = dueGearGauges([
        _clocks(_item('Reg early', EquipmentType.regulator), [
          _status(ServiceClockSeverity.dueSoon, dueDate: DateTime(2026, 8, 1)),
        ]),
        _clocks(_item('Reg late', EquipmentType.regulator), [
          _status(ServiceClockSeverity.dueSoon, dueDate: DateTime(2026, 8, 9)),
        ]),
      ]);
      expect(result.gauges.map((g) => g.itemName), ['Reg early']);
    });

    test('caps overdue items and reports the overflow', () {
      final result = dueGearGauges([
        for (var i = 0; i < 7; i++)
          _clocks(_item('Reg $i', EquipmentType.regulator), [
            _status(
              ServiceClockSeverity.overdue,
              dueDate: DateTime(2026, 6, 1 + i),
            ),
          ]),
      ]);
      expect(result.gauges.map((g) => g.itemName), [
        'Reg 0',
        'Reg 1',
        'Reg 2',
        'Reg 3',
      ]);
      expect(result.overdueOverflow, 3);
    });

    test('overdue items take precedence over due-soon for the total cap', () {
      final result = dueGearGauges([
        for (var i = 0; i < 4; i++)
          _clocks(_item('Overdue $i', EquipmentType.regulator), [
            _status(
              ServiceClockSeverity.overdue,
              dueDate: DateTime(2026, 6, 1 + i),
            ),
          ]),
        _clocks(_item('Soon BCD', EquipmentType.bcd), [
          _status(ServiceClockSeverity.dueSoon, dueDate: DateTime(2026, 8, 1)),
        ]),
        _clocks(_item('Soon computer', EquipmentType.computer), [
          _status(ServiceClockSeverity.dueSoon, dueDate: DateTime(2026, 8, 2)),
        ]),
        _clocks(_item('Soon light', EquipmentType.light), [
          _status(ServiceClockSeverity.dueSoon, dueDate: DateTime(2026, 8, 3)),
        ]),
      ]);
      // cap of 6: four overdue chips claim their slots first, leaving two
      // for the due-soon chips.
      expect(result.gauges, hasLength(6));
      expect(result.gauges.map((g) => g.itemName).skip(4), [
        'Soon BCD',
        'Soon computer',
      ]);
    });

    test('an overdue item suppresses the due-soon chip for its type', () {
      final result = dueGearGauges([
        _clocks(_item('Reg overdue', EquipmentType.regulator), [
          _status(ServiceClockSeverity.overdue, dueDate: DateTime(2026, 6, 1)),
        ]),
        _clocks(_item('Reg soon', EquipmentType.regulator), [
          _status(ServiceClockSeverity.dueSoon, dueDate: DateTime(2026, 8, 1)),
        ]),
      ]);
      expect(result.gauges.map((g) => g.itemName), ['Reg overdue']);
    });

    test('a cap tighter than the overdue cap still bounds the whole list', () {
      // cap is the advertised bound on the result, so it has to bound the
      // overdue slice too, and the items it excludes count as overflow.
      final result = dueGearGauges([
        for (var i = 0; i < 5; i++)
          _clocks(_item('Reg $i', EquipmentType.regulator), [
            _status(
              ServiceClockSeverity.overdue,
              dueDate: DateTime(2026, 6, 1 + i),
            ),
          ]),
      ], cap: 2);
      expect(result.gauges.map((g) => g.itemName), ['Reg 0', 'Reg 1']);
      expect(result.overdueOverflow, 3);
    });

    test('an item with several clocks contributes its worst clock once', () {
      final result = dueGearGauges([
        _clocks(_item('Reg', EquipmentType.regulator), [
          _status(ServiceClockSeverity.overdue, dueDate: DateTime(2026, 6, 1)),
          _status(ServiceClockSeverity.overdue, dueDate: DateTime(2026, 5, 1)),
          _status(ServiceClockSeverity.dueSoon, dueDate: DateTime(2026, 8, 1)),
        ]),
      ]);
      expect(result.gauges, hasLength(1));
      expect(result.gauges.single.status.dueDate, DateTime(2026, 5, 1));
    });
  });
}
