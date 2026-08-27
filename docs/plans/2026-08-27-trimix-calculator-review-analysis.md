# Trimix Calculator Review — Analysis (Issue submersion-app/submersion#1335)

Date: 2026-08-27

## Scope

This is Part 1 (analysis only) of a two-part task. No calculation logic,
tests, or UI were changed in this PR. Part 2 (fixing any confirmed
discrepancies) is a follow-up once the dataset comparison below can actually
be completed.

## What "Trimix-Rechner" maps to in this codebase

There is no feature literally named "Trimix Calculator". The reported app
version (Android 1.7.6.7077) matches `pubspec.yaml`'s `1.7.6+123`, and the
described input ("Füllgastemperatur 20°" / fill gas temperature) only exists
on the **Gas Blender Calculator**, so that is the feature in scope:

- `lib/features/gas_calculators/domain/gas_blender.dart` — solver
  (`computeBlend`), partial-pressure blending for up to three fill gases
  (O2 / He / air), producing a step-by-step fill procedure.
- `lib/features/gas_calculators/domain/blending/equation_of_state.dart` —
  equation-of-state layer (`molarDensity` / `pressureAt` / `zFactor`) used to
  convert between cylinder pressure and gas amount.
- `lib/features/gas_calculators/presentation/widgets/gas_blender_calculator.dart`
  and `presentation/widgets/blender/*` — the UI, including the fill/settled
  temperature inputs (`blender_conditions_card.dart`).
- `lib/features/gas_calculators/presentation/providers/gas_blender_providers.dart`,
  `domain/blending/blender_preferences.dart` — stores the selected equation
  of state (`BlendGasModel`) as a user preference.

## Current calculation model

- The solver conserves **molar density** (moles of gas per litre of cylinder
  volume), not pressure or volume, because mixing gases adds moles exactly
  while pressure/volume addition is only approximate for real gases
  (`gas_blender.dart:16-19`).
- Three interchangeable equations of state (`BlendGasModel` in
  `equation_of_state.dart`):
  - `ideal`: `p = ρRT` (matches hand calculation and most published blending
    tables).
  - `zFactor` (**default**): virial compressibility factor, fit per-gas
    around `kReferenceTempC = 20°C`, cubic in pressure, clamped at 500 bar.
  - `vanDerWaals`: one-fluid mixing rule; per the code's own accuracy note it
    is *less* accurate than `zFactor` at fill pressure and overshoots roughly
    as much as `ideal` undershoots.
- Fill temperature and settled temperature are independent inputs
  (`GasBlenderInputs.fillTempC` / `settledTempC`), both defaulting to
  `kReferenceTempC = 20°C` — i.e. the calculator already defaults to the
  20°C fill temperature mentioned in the issue.
- For a 3-gas (trimix) target, `_solveTops` solves an exact 3x3 linear system
  (Cramer's rule) in O2/He/N2 fractions; for a helium-free target it falls
  back to a 2-gas linear solve.
- Gas order is O2 → He → air by default so the compressor tops off with air
  last, matching how fill stations actually operate
  (`_selectFillGases`/`gas_blender.dart:208-228`).

## Existing correctness baseline

`test/features/gas_calculators/domain/gas_blender_test.dart` already
cross-checks the Dart solver against a reference JavaScript blender
("Blei-Log") for both a nitrox case (empty → EAN32) and a trimix case
(empty → 18/45 from O2 + He + air at 200 bar), matching intermediate
pressures and added volumes to within 0.05 bar/L. This gives a known-good
reference point independent of the issue's dataset, but it only covers two
scenarios, not the range in `trimix_berechnungen.xlsx`.

## Blocker: could not access the dataset or the original issue

This run does not have permission to use the `gh` CLI or `WebFetch` (both
`gh issue view/api ...` and `WebFetch` against `github.com` were rejected
with "requires approval", and there is no human present in this automated
context to grant it). As a result:

- `trimix_berechnungen.xlsx`, referenced as attached to
  submersion-app/submersion#1335, could not be downloaded or read.
- The original issue #1335's body/comments (which may contain more detail
  than what was relayed into this fork's issue #17) could not be fetched
  either.
- The repository itself contains no `.xlsx` files and no prior copy of this
  dataset (`git ls-files` / `**/*.xlsx` came back empty), so there is nothing
  locally to compare against.

**Consequence:** the actual "compare dataset values against current
implementation, document deviations" step this issue asks for could not be
performed. No calculation errors are confirmed or ruled out by this PR.

## What would unblock this

Either of the following would let a follow-up run complete the comparison:

1. Grant `Bash(gh:*)` (or network access for `WebFetch` against
   `github.com`/`objects.githubusercontent.com`) in the workflow's
   `--allowedTools`, so the attachment on submersion-app/submersion#1335 can
   be fetched directly, or
2. Paste the dataset's rows directly into a comment on this issue (start
   pressure/mix, target pressure/mix, fill gases, expected intermediate
   pressures or volumes per row) so they can be diffed against
   `computeBlend` output without needing file access.

Once the dataset is available, Part 2 should add one test per row of
`trimix_berechnungen.xlsx` to
`test/features/gas_calculators/domain/gas_blender_test.dart`, matching the
existing "reference implementation" test style shown above.
