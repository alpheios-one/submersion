# CCR O2 Cell Millivolt Graph — Design

**Date:** 2026-08-15
**Status:** Approved for planning
**Issue:** [#810](https://github.com/submersion-app/submersion/issues/810)
**Schema:** v150 → v151 (re-verify against `origin/main` before writing the migration)
**Delivery:** one PR, full vertical slice

## Problem

Issue #810 reports that CCR sensor readings are missing from the dive profile on a
Shearwater Petrel 3. The investigation established why: the Petrel writes a factory
default calibration value (2100) for every O2 cell rather than the real calibration,
so libdivecomputer could not convert cell output into a partial pressure and
suppressed the per-cell samples entirely.

The libdivecomputer side is now fixed and merged (submersion-app/libdivecomputer
PR #2, submodule at `08bf592`). The parser reports each calibrated cell with its raw
output in the new `dc_sample_value_t.ppo2.millivolt` field, and sets `value` to `NAN`
when the logged calibration cannot be trusted — the measurement is delivered, the
guessed conversion is not.

Nothing in the app consumes it. `libdc_download.c` reads `value->ppo2.value` and
discards `millivolt`, so for these dives the wrapper's NaN guard turns every cell
into `null` and the diver still sees nothing. The graph work and the plumbing work
are the same task: there is no rendering to build until millivolts are persisted.

## Goals

1. Carry per-cell millivolts from libdivecomputer to the database across all five
   platform paths.
2. Draw the cells as a selectable right-axis metric on the dive profile chart, one
   line per cell, so a diverging cell is visible at a glance.
3. Show millivolts alongside the existing per-cell ppO2 in the profile tooltip.
4. Change nothing for dives that have no millivolt data.

## Non-goals

- **Inferring a calibration.** Where the logged calibration is untrusted, ppO2 per
  cell stays absent. Showing a computed partial pressure anchored to a placeholder
  would be a fabricated number presented as a measurement.
- **Bulk backfill via migration.** See "Backfill" below — it is neither needed nor
  possible for the dives that motivated the issue.
- **Storing `raw_data` on file import.** Worth doing, but its own feature.
- **A persisted default-visibility setting.** Session-only toggle for now; see
  "Toggle" below.
- **Millivolt support in other parsers.** Only the Shearwater parser was patched
  upstream. The pipeline is parser-agnostic and will carry any future source.

## Backfill

No migration and no new code. Millivolts arrive by re-running the parser:

- **BLE/serial downloads** store the raw blob (`dive_data_sources.raw_data`, written
  only at `dive_computer_repository_impl.dart:1236`), so the existing manual
  re-parse path picks up millivolts.
- **File imports** — including the Shearwater Cloud `.db` export in #810 — store no
  blob, so re-parse is unavailable for them. Re-importing the same file works: the
  Shearwater and MacDive importers both route through `parseRawDiveData()`, the same
  libdivecomputer FFI entry point as a download.

An auto-migration was considered and rejected: it is impossible for file-imported
dives (no stored blob), and for downloaded dives it would run libdivecomputer over
every blob during startup migration while silently rewriting other
computer-authored fields.

## Storage model

Six nullable INTEGER columns `o2_sensor_mv1..6` on `dive_profiles`, parallel to the
existing `o2_sensor1..6`.

Every layer already has a six-wide shape to extend — `dc_sample_t.o2_sensor[6]`,
`ProfileSample.o2Sensor1..6`, `DiveProfilePoint.o2Sensor1..6`, `_cellAccessors` in
the resolver — so the change is mechanical at each one, which is what matters when
it has to survive five hand-written platform marshallers.

Two alternatives were considered:

- **Three columns instead of six.** Only the Shearwater parser supplies millivolts
  and it reads exactly three cells. Rejected: it breaks the 1:1 correspondence with
  `o2_sensor1..6`, giving the bar accessors and the millivolt accessors different
  lengths — exactly the asymmetry that invites the cell-labelling off-by-one the
  resolver comments work to prevent.
- **A normalized `dive_profile_o2_cells` table.** The better schema in the
  abstract. Rejected for this change: it migrates existing cell data out of
  `dive_profiles` and rewrites every reader, triples the row count of the largest
  table, and adds a join to a flat read path. A schema refactor wearing a feature's
  clothes; worth its own issue if the cell model keeps growing.

Rejected outright: overloading the existing `o2_sensor` columns with a unit flag.
One column instead of six, but "is this bar or millivolts" becomes a runtime
question at every read site, and it changes the meaning of already-synced data.

Cost: `dive_profiles` is the hottest table in the schema (one row per sample) and
this widens it by six columns. A NULL column costs about one byte in the SQLite
record header, so an OC dive pays roughly six bytes per sample.

## Data path

### Sentinel

`unsigned int o2_sensor_mv[6]` on `libdc_sample_t`, using `UINT32_MAX` for absent to
match every other unsigned field in that struct (`heartbeat`, `rbt`, `deco_type`,
`gasmix`, `heading`).

Not zero. Zero is what libdivecomputer sends for "this device does not report
millivolts", and if it reached Dart as a value every non-Shearwater CCR would render
a flat 0 mV line.

The capture in `libdc_download.c` therefore writes the millivolt only when it is
non-zero, leaving `UINT32_MAX` otherwise.

**Accepted limitation:** a cell reading exactly 0 mV is stored as absent rather than
as zero. A galvanic cell at 0 mV is disconnected or dead, and this is the contract
the merged `parser.h` states ("zero when the device does not report it").
Distinguishing the two would need a separate presence flag through all five
platforms to describe a state that means "broken" either way.

### Platform marshalling

| Platform | Site | Shape |
| --- | --- | --- |
| Pigeon | `pigeons/dive_computer_api.dart:100` | `final int? o2SensorMv1..6`, then regenerate all five outputs |
| Darwin | `DiveComputerHostApiImpl.swift:648` | C array imports as a 6-tuple; `UInt32.max` → nil |
| Android JNI | `libdc_jni.cpp:1011` | positional `jdouble[]`, **append only** — see below |
| Android Kotlin | `DiveComputerHostApiImpl.kt:657`, `SerialDownloadRunner.kt:182` | positional reads, two separate files |
| Windows | `dive_converter.cc:159` | `std::optional` + `&*x : nullptr` |
| Linux | `dive_converter.c:138` | positional args to `..._profile_sample_new()` |

### The Android positional-array hazard

Android does not marshal by field name. `libdc_jni.cpp` packs a `jdouble values[22]`
and two Kotlin files index it positionally. A mismatch produces no compile error on
either side — it silently misreads every field after the insertion point.

Millivolts are **appended** at indices 22–27, growing the array to 28. Never
inserted mid-array, which would renumber `gasMixIndex` (20) and `heading` (21).

There is a precedent for this exact move: when `heading` was appended at index 21,
the Kotlin readers guarded it as `if (s.size < 22 || ...)`. The millivolt reads
follow that idiom with `s.size < 28`, so a stale `.so` degrades to null instead of
throwing.

Mitigation is structural as well as tested: named index constants on both sides plus
a shared field-count constant, so the array size and the highest index cannot drift
apart silently.

### Persistence layers

- `DiveProfilePoint` (`dive.dart:795-800`) gains six fields, threaded through the
  constructor, `copyWith`, and `props`.
- Row⇄entity mapping in `dive_repository_impl`; Pigeon→companion mapping in
  `parsed_dive_mapper` and `parsed_dive_profile_mapper`.
- Sync: `SyncData.diveProfiles` is `List<Map<String, dynamic>>`, which suggests new
  columns ride along automatically. Verify how the map is built rather than assume;
  if it enumerates columns explicitly, add the six there.
- Unchanged: UDDF and Subsurface XML carry no millivolt field. The Shearwater `.db`
  and MacDive importers need no change — they already route through
  `parseRawDiveData()` and inherit millivolts for free.

## Migration

Version bump 150 → 151. `origin/main` is at 150 and no open PR claims 151 as of
2026-08-15 (PR #603 claims 138, PR #954 claims 149) — re-verify before writing it.

All four steps of the schema-bump checklist:

1. PRAGMA-guarded idempotent helper `_assertO2SensorMvColumns()`, cloning the v89
   loop at `database.dart:7089-7101`. Never a bare `addColumn`: the partial-schema
   migration tests instantiate old databases without unrelated tables and crash on
   unguarded DDL.
2. Called from **both** the `if (from < 151)` block and the `beforeOpen` backstop,
   with `151` appended to `migrationVersions`.
3. The exact-latest schema tripwire test updated.
4. Not applicable — that step covers non-nullable columns needing a sync default
   seed, and these are nullable.

## Rendering

### Curve derivation

`o2CellMvCurves` is derived directly from the profile in `overlayComputerDecoData`,
**not** hung off `RebreatherPpO2.sensorCurves`.

`resolveRebreatherPpO2` gates on `hasCells`, which tests the *bar* values. For an
untrusted-calibration dive every cell's bar value is null, so `hasCells` is false and
only the `DC_SENSOR_NONE` aggregate keeps the resolver alive. Deriving millivolts
there would make the graph's existence depend on an unrelated aggregate sample: a
computer reporting cells with no aggregate would have millivolts in the database and
no way to draw them.

The derivation reuses the existing shape — `List<List<int?>>`, index `i` == cell
`i+1`, length set by the highest cell with any reading, lower cells left as all-null
curves — on its own `_cellMvAccessors`. It rides onto `ProfileAnalysis` as a sibling
of `o2SensorCurves` and flows through the four existing call sites (dive detail page,
profile panel, fullscreen page, and the redesign plan doc).

### The metric

`ProfileRightAxisMetric.o2CellMv`, category `gasAnalysis`, `unitSuffix: 'mV'`.

Three switches over that enum are exhaustive with no `default` — `_hasDataForMetric`,
`_getMetricRange`, `_formatRightAxisValue` — so the analyzer names every site that
needs updating. `_rightAxisLabel` falls through to its `default`, building the label
from `shortName` and `unitSuffix`, so `shortName` must read well there.

Deliberately **not** added to `fallbackPriority`: it is a diagnostic metric, and
joining that list would auto-select it on CCR dives whenever temperature is absent.

Axis range zero-anchored and data-driven, `(min: 0.0, max: maxMv * 1.2)`, following
the `sac` and `meanDepth` precedent. Cells sit around 30–70 mV, so a zero-anchored
axis still separates a cell drifting to 40 from siblings at 55 while keeping the
scale honest across dives.

### Lines

`_buildO2CellMvLines(MetricBand band)` returns `List<LineChartBarData>`, spread into
the existing list beside the ppO2 line. One line per cell, in graded shades of a
single hue so they read as one metric with three members.

Unlike `_buildPpO2Line`, these get **no** surface lead-in and no carry-forward across
gaps. Per-cell curves have genuine dropouts, and a broken line is the honest
rendering of a cell that stopped reporting.

### Toggle

`showO2CellMv` joins `ProfileLegendState`: field, constructor, `copyWith`, `==`,
`hashCode`, `activeSecondaryCount`, and `toggleO2CellMv()`.

Session-only, with no persisted default setting. `showMod` is the precedent
(`showMod: false, // MOD not in settings yet`). A `defaultShowO2CellMv` would mean a
*second* schema column — a non-nullable bool on `diver_settings` — which drags in
step 4 of the schema checklist (the `_applyDiverSettingDefaults` seed and a
legacy-payload sync test). Not worth it for a first cut, and easy to add later.

### Tooltip

The existing per-cell rows, and the mirrored fullscreen block, get one combined row
per cell rather than a second set:

- bar and millivolts present → `Sensor 1    0.98 bar (58 mV)`
- millivolts only, untrusted calibration → `Sensor 1    58 mV`
- bar only → unchanged

This keeps tooltip height fixed and puts both readings for one physical cell on one
line.

## Testing

TDD throughout, red first.

**Native (CMake suite).** Extend `test_parse_raw_dive`, which already links
`libdc_download.c` and has the `petrel3_ccr_o2_cells.bin` fixture. Assert that
millivolts land in `o2_sensor_mv[0..2]` within 10–120, that cells 3–5 stay
`UINT32_MAX`, and that the aggregate sample writes no millivolt. This is the test
that proves the capture line, and the merged libdivecomputer test already pins the
expected values (419 samples, 38–81 mV).

**Android decoder.** The highest-risk layer. Named index constants plus a shared
field-count constant are the primary mitigation. `DiveMarshalingTest.kt` lives in
`androidTest` (instrumented, not runnable in CI); check whether a JVM `src/test`
source set exists and add a decoder test there against a synthetic `DoubleArray`. If
no JVM source set exists, say so plainly rather than imply the decoder is covered.

**Migration.** A v150→v151 test in `test/core/database/`, modelled on
`migration_v89_o2_cells_test.dart`, including the partial-schema case the PRAGMA
guard exists for. Plus the tripwire update.

**Dart unit.** Mapper tests (Pigeon `ProfileSample` → companion); repository
round-trip (write six, read six back); and resolver tests — the important one being
that `o2CellMvCurves` is built for a profile with millivolts and **no** bar values
and **no** aggregate ppO2, the case the current gating would drop.

**Widget.** Metric offered only when millivolt data exists; three
`LineChartBarData` entries for three cells; a mid-dive gap producing a broken line
rather than an interpolated one; all three tooltip row shapes.

### Not claimed

The Windows, Linux, and Darwin marshallers are compile-checked but executed by no
test — the same status as the existing `o2Sensor1..6` fields. They are
reviewed-not-tested, and the plan should not imply otherwise.
