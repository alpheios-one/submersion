# Dive Site Statistics — Analysis

Upstream issues: submersion-app/submersion#1018, submersion-app/submersion#1038

## Overview

The dive site detail view currently shows only a manually entered depth
range (`DiveSite.minDepth`/`maxDepth`) and the number of dives logged at the
site. This document analyzes what it would take to add an auto-computed
statistics section, aggregated over the dives actually assigned to a site:

- Deepest dive (max depth)
- Shallowest dive (min depth)
- Longest dive (duration)
- Average dive duration
- Date of first and last dive
- Dive count (already exists, kept)

This is analysis only — no schema, UI, or logic changes are made in this
pass.

## 1. Dive <-> dive site relationship

`lib/core/database/database.dart`:

- `Dives.siteId` (line 691) — nullable `TextColumn` FK: `references(DiveSites, #id)`.
- Relevant per-dive columns: `maxDepth` (line 662, meters, no `minDepth`
  column exists on `Dives`), `bottomTime`/`runtime` (lines 660-661, seconds),
  `entryTime`/`exitTime` (lines 656-658), `diveDateTime` (line 654, the
  canonical sort/filter timestamp used throughout the SQL layer).
- `DiveSites` table: lines 914-959.

Domain entities: `Dive` (`lib/features/dive_log/domain/entities/dive.dart`,
line 19) and `DiveSite`
(`lib/features/dive_sites/domain/entities/dive_site.dart`, line 35).

## 2. Existing dive-count-per-site query

`lib/features/dive_sites/data/repositories/site_repository_impl.dart`:

- `getDiveAggregatesBySite()` (lines 863-896) is a single `GROUP BY site_id`
  query across the whole `dives` table (used to build the site *list*, not
  scoped to one site):

  ```sql
  SELECT site_id, COUNT(*) AS dive_count,
         MAX(dive_date_time) AS last_dived,
         MAX(max_depth) AS max_depth_reached
  FROM dives
  WHERE site_id IS NOT NULL
  GROUP BY site_id
  ```

  Returns `Map<String, SiteDiveAggregate>`
  (`lib/features/dive_sites/domain/entities/site_with_dive_count.dart`,
  lines 8-21) — only `diveCount`, `lastDivedAt`, `maxDepthReached` today, no
  min depth or duration stats.
- The detail page's dive count comes from `siteDiveCountProvider`
  (`site_providers.dart`, line 309), which filters the whole-app
  `sitesWithCountsProvider` list down to one site id **in memory** — it does
  not run a per-site SQL query today.

This GROUP-BY-all-sites query is not the right base to extend for a
single-site detail view. The right template is the single-site,
`WHERE site_id = ?`-scoped pattern already used elsewhere (see §5).

## 3. Dive site detail screen / "Dive Info" section

- `lib/features/dive_sites/presentation/pages/site_detail_page.dart`:
  `SiteDetailPage` (line 43, routing/loading) wraps `_SiteDetailContent`
  (line 142), which renders the body as an ordered list of
  `_build*Section(...)` methods (lines 170-287), each in its own `Card`.
  - `_buildDiveCountSection()` (lines 670-791) — existing dive count, an
    async `.when()`-driven card backed by `siteDiveCountProvider`. This is
    the pattern a new stats section should follow, since it also needs a
    new provider.
  - `_buildDepthSection()` (lines 996-1122) — labeled "Depth Range" in the
    UI; reads `site.minDepth`/`site.maxDepth` directly off the `DiveSite`
    object (no provider), formatted via `UnitFormatter`.
- The "Dive Info" group label itself
  (`diveSites_edit_group_diveInfo`) belongs to the **edit** page, not the
  detail page: `DiveInfoSection`
  (`lib/features/dive_sites/presentation/widgets/edit_sections/dive_info_section.dart`,
  line 12) renders the `minDepthController`/`maxDepthController` text
  fields (lines 84-95) that back the manual values shown read-only in
  `_buildDepthSection`.

A new computed-statistics section fits naturally as its own `Card`
(`_buildDiveStatisticsSection`), inserted after `_buildDepthSection` and
before `_buildDiveCountSection`/altitude in the `_SiteDetailContent` column
(around line 199), clearly separated from — not merged into — the manual
depth-range card.

## 4. Manual min/max depth fields

Confirmed distinct from any dive-level field:

- `DiveSites.minDepth` / `DiveSites.maxDepth`
  (`database.dart`, lines 921-922) — manually entered, describe the site's
  own characteristics (e.g. "this reef ranges 5m-30m"), edited via
  `DiveInfoSection`.
- `Dives.maxDepth` (`database.dart`, line 662) — the depth actually reached
  on one logged dive. There is no `minDepth` column on `Dives` at all.

The computed statistics must use distinct naming (e.g. a
`SiteDiveStatistics` value object, not fields on `DiveSite`) so they are
never confused with — or accidentally overwrite — the manual
`DiveSite.minDepth`/`maxDepth` values.

## 5. Reusable statistics/aggregation logic

`lib/features/statistics/data/repositories/statistics_repository.dart`
(`StatisticsRepository`, line 93) is the app's general-purpose SQL
aggregation repo and already has the exact shape needed:

- Single-site scoped query template —
  `getEntryExitMethodPairsForSite({required siteId, diverId})`
  (lines 1298-1334): `WHERE site_id = ? [AND diver_id = ?]`, raw
  `customSelect(...).get()`, wrapped in try/catch with `_log.error(...)` on
  failure (repo-wide error-handling convention).
- Multi-stat single-row query pattern (COUNT + MIN/MAX depth + MIN/MAX date
  in one call): `getSpeciesStatistics` (lines 1794-1807).
- `AVG` duration pattern: `getBottomTimeTrend` (lines 903-912),
  `AVG(bottom_time / 60.0) AS avg_duration`.
- Filter-composition helper, if the new query should also honor the app's
  diver-scoping conventions: `dive_filter_sql.dart`,
  `buildFilteredDiveIdSubquery()` (line 12).
- Value-object pattern to mirror for the result:
  `CareerTotals` (`lib/features/statistics/domain/career_totals.dart`,
  lines 5-72) — plain `Equatable` value object with a `factory .from(...)`
  and formatting helpers.

Recommended approach: add one new method,
`StatisticsRepository.getSiteDiveStatistics({required siteId, diverId})`,
combining `COUNT(*)`, `MIN/MAX(max_depth)`, `MIN/MAX(dive_date_time)`, and a
duration aggregate in a single `.getSingle()` query scoped by
`WHERE site_id = ?` — no new table/migration needed, everything is derived
from existing `dives` columns.

**Duration caveat:** `Dive.effectiveRuntime`
(`dive.dart`, lines 305-322) has a 4-step fallback chain
(`runtime` -> `exitTime - entryTime` -> profile-derived calculation ->
`bottomTime`) — the profile-derived step cannot be expressed in SQL. For
the aggregate query, the pragmatic simplification is
`COALESCE(runtime, bottom_time)` (skipping the entry/exit-diff and
profile-derived steps), which will slightly undercount duration stats for
dives that only have `entryTime`/`exitTime` or profile data but no
`runtime`/`bottomTime`. This tradeoff should be called out explicitly in
the implementation PR.

## 6. Localization

ARB files: `lib/l10n/arb/app_en.arb` (+ one `app_<lang>.arb` per locale).
Existing dive-site-detail keys follow `diveSites_detail_*`
(`app_en.arb`, lines 4711-4754), e.g. `diveSites_detail_section_depthRange`,
`diveSites_detail_section_divesAtSite`, `diveSites_detail_depth_minimum`,
`diveSites_detail_diveCount_zero/_one/_other`.

New keys should follow the same scheme:
`diveSites_detail_section_diveStatistics`,
`diveSites_detail_stats_maxDepth`, `diveSites_detail_stats_minDepth`,
`diveSites_detail_stats_longestDive`, `diveSites_detail_stats_avgDuration`,
`diveSites_detail_stats_firstDive`, `diveSites_detail_stats_lastDive`,
`diveSites_detail_stats_noData` (empty-state message when the site has no
dives yet).

## 7. Provider wiring

`lib/features/dive_sites/presentation/providers/site_providers.dart`:

- `statisticsRepositoryProvider` is already imported and used in this file
  (line 18 / line 334 via `siteEntryExitSuggestionProvider`), so no new DI
  wiring is required.
- Template to copy: `siteEntryExitSuggestionProvider` (lines 326-352) —
  `FutureProvider.family<T, String>`, watches
  `diveRepository.watchDivesChanges()` via `ref.invalidateSelfWhen(...)` for
  live refresh when dives change.
- A new `siteDiveStatisticsProvider` should be a
  `FutureProvider.family<SiteDiveStatistics, String>` keyed by `siteId`,
  following that exact invalidation pattern, calling the new
  `StatisticsRepository.getSiteDiveStatistics(...)` method.
- Widget-side consumption follows `_buildDiveCountSection`'s
  `ref.watch(...).when(data:, loading:, error:)` idiom
  (`site_detail_page.dart`, line 676).

## Units and formatting

Depths are stored in meters and durations in seconds at the data layer;
existing convention (see doc comment on `SiteDiveAggregate`,
`site_with_dive_count.dart` line 7: "Depths are stored in metres; convert
at the display edge") is to convert only at render time via
`UnitFormatter` (`lib/core/utils/unit_formatter.dart`), respecting the
active diver's metric/imperial settings. The new stats card should reuse
`UnitFormatter` rather than formatting values itself.

## Empty state

If a site has zero associated dives, `getSiteDiveStatistics` returns a
`diveCount` of 0 with all other fields `null` (SQL `MIN`/`MAX`/`AVG` over
zero rows yield `NULL`). The UI should treat `diveCount == 0` as "no data
yet" and either hide the new statistics card or show the
`diveSites_detail_stats_noData` message, per the issue's requirement to
avoid displaying misleading zero values.

## Summary of the minimal change set (for the implementation follow-up)

1. `StatisticsRepository`: add `getSiteDiveStatistics({required siteId, diverId})`.
2. New value object `SiteDiveStatistics` (near `site_with_dive_count.dart`
   or alongside `CareerTotals`).
3. `site_providers.dart`: new `siteDiveStatisticsProvider`
   (`FutureProvider.family<SiteDiveStatistics, String>`).
4. `site_detail_page.dart`: new `_buildDiveStatisticsSection`, inserted
   after `_buildDepthSection`, styled like the existing section builders.
5. New `diveSites_detail_*` ARB keys across all locale files.
6. No Drift schema/migration changes needed.
