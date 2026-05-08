# Changelog

All notable changes to Vellum are recorded here. The convention is
sequential integer build numbers, one increment per `.dev/release.ps1`
run. Higher numbers are newer.

The format is loosely based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **Drag-position persistence.** Cairn-Gui-Widgets-Standard-2.0 MINOR=5 added a `"Moved"` event on Window; MINOR=6 then made it actually correct (MINOR=5 fired Moved with raw `GetPoint(1)` coords that were `BOTTOMLEFT`-relative after `StartMoving`/`StopMovingOrSizing` rewrote the anchor; persisting them and restoring via `SetPoint("CENTER", UIParent, "CENTER", x, y)` made the window jump on `/reload`. MINOR=6 normalizes the frame back to `CENTER`-relative coords inside `OnDragStop` and fires Moved with those, so the persisted `(x, y)` is always an offset from `UIParent` center). `Panel.lua` subscribes via `win.Cairn:On("Moved", function(_, x, y) ... end)` and writes `db.profile.panel.x/y` so the panel position round-trips across `/reload`. Previously the panel would re-center on every login because the lib had no Moved callback to drive saved-variable writes.

### Removed

- **`Panel.lua` `fixButtonClicks(btn)` workaround** — removed all 4 call sites and the helper itself. `Cairn-Gui-Widgets-Standard-2.0` MINOR=4 now ships the framework-level fix: `Button.OnAcquire` calls `frame:RegisterForClicks("AnyUp")` so consumer code no longer needs the per-row workaround. A short historical-reference comment stays at the original location for git-blame breadcrumbs.

### Added

- **`Panel.lua`** — first real consumer of `Cairn-Gui-2.0`. A movable Window with a header banner (Vellum logo + current quest title + objective body) above a `TabGroup` carrying three tabs:
  - **Log** — lists `C_QuestLog` entries; click a row to follow. Refreshes on `QUEST_LOG_UPDATE` while the tab is selected.
  - **Zone** — scans `LibCodex Quests:AllRaw()` filtered to the player's current `mapID` and faction side (`A` / `H` / `B`). Refreshes on `ZONE_CHANGED_NEW_AREA`. Caps at 200 rendered rows with an overflow note.
  - **Search** — `EditBox` drives live filtering by quest ID (fast-path `Quests:Get`) or partial label match. Caps at 50 rows.
- **`Logo.png`** — 128x128 RGB asset packaged for in-client display. Embedded in the panel header via WoW's inline-texture syntax (`|TInterface\AddOns\Vellum\Logo:24:24|t`) so consumers stay inside Cairn-Gui widgets without raw `CreateTexture`. The 1254x1254 master `VellumLogo.png` stays in the source tree but `.pkgmeta` ignores it from the published zip.
- **`/vellum panel`** slash subcommand toggles the panel.
- **`db.profile.panel`** schema with `x`, `y`, `autoShow`, `autoHideOnClear`, `selectedTab`. Replaces the v0.1 `db.profile.window` schema.

### Changed

- **`Vellum.toc`** loads `Panel.lua` in place of `Window.lua`.
- **`Core.lua`** `/vellum stop` now hides `ns.Panel` rather than `ns.Window`. Slash router gains the `panel` subcommand.

### Removed

- **`Window.lua`** — replaced by `Panel.lua`. Backwards-compat shim inside `Panel.lua` aliases `ns.Window.Show / Hide / SetText / IsShown / Center` onto the corresponding `Panel` methods so existing call sites that haven't been updated yet keep working.

## [1] — Vellum v0.1: single-quest follower (2026-05-03)

Initial public build. Vellum is a leveling guide that follows one quest
at a time, points an arrow at the next objective, and auto-advances when
that objective completes.

### Added

- **`Vellum.toc`** — Interface 120005 (Retail Midnight). Hard
  dependencies on `LibCodex-1.0` and `Cairn`; optional `TomTom`. Saved
  variables in `VellumDB`. Distribution stamps included as commented
  placeholders for CurseForge / WoWInterface / Wago project IDs.
- **`Core.lua`** — Bootstrap on the Cairn framework: `Cairn.Addon` for
  lifecycle (OnInit / OnLogin), `Cairn.DB` for saved-variable wiring
  with profile defaults, `Cairn.Slash` for the `/vellum` command set
  with auto-help, `Cairn.Log` for logging. Public slash commands:
  `status`, `codex`, `reset`, `follow [id|name]`, `stop`. `follow` with
  no argument adopts the currently supertracked quest; with an
  argument accepts a questID or partial-name match against the player
  quest log.
- **`Locator.lua`** — Three-layer coordinate resolver. Contract
  `Locator.Resolve(questID, objectiveIndex)` returns
  `mapID, x, y, source` where `source` is one of `"blizzard"`,
  `"codex-poi"`, `"codex-turnin"`, `"codex-giver"`, or `"missing"`.
  `objectiveIndex == nil` resolves the turn-in. Fallback order:
  (1) `C_QuestLog.GetNextWaypoint`, (2) the LibCodex `Quests` entry's
  giver/turn-in coords, (3) LibCodex `QuestPOI:ForQuest` by
  objectiveIndex. The 1-based Blizzard objective index is converted to
  the 0-based LibCodex POI index internally.
- **`Follower.lua`** — Quest-event observer. Tracks one quest's state
  (`questID`, `questTitle`, `objectiveIndex`, `objectiveText`,
  `isComplete`, `mapID/x/y`, `source`). Public API:
  `Set(qid)`, `Clear()`, `Refresh()`, `Get()`,
  `OnChange(fn) -> unsubscribe-closure`. Subscribes to
  `QUEST_LOG_UPDATE`, `UNIT_QUEST_LOG_CHANGED` (filtered to
  `"player"`), `QUEST_ACCEPTED`, `QUEST_REMOVED` (clears if it was
  ours), `QUEST_TURNED_IN` (same).
- **`Arrow.lua`** — Wax-seal compass arrow matching the Cairn / Codex
  / Vellum brand family (parchment + ink + wax). Five visual layers:
  parchment disc (square color masked to a circle via
  `TempPortraitAlphaMask`), brass ring atlas
  (`QuestPortraitBorder-Round`, fallback `common-iconframe`),
  rotating wax-red chevron (`Waypoint-MapPin-Untracked`, fallback
  `Minimap-PositionArrows`, fallback `Interface\Cursor\Point`), ink-dot
  pivot, parchment-ink label + distance below. Position persisted via
  `db.profile.arrow.x/y/scale`.
- **`Window.lua`** — Sticky guide panel. Parchment background with
  ink-colored border, `GameFontNormalLarge` title in dark-brown
  ink-tone, thin ink divider, `GameFontNormal` body with three-line
  wrap. Backdrop via `BackdropTemplate` + `UI-Tooltip-Background` and
  `UI-Tooltip-Border` textures, tinted to look like an ink-bordered
  scroll fragment.

### Distribution

- **License:** All Rights Reserved (end-user addon, not a library).
- **Single-flavor:** Retail (Interface 120005). Mists / TBC / Vanilla /
  XPTR support is not in scope for v0.1.
- **Pipeline:** GitHub Actions calls `BigWigsMods/packager@v2` on tag
  push. Local `.dev/release.ps1` bumps `## Version:` in `Vellum.toc`,
  commits, tags, pushes. CF / WoWI / Wago uploads run only when the
  matching repository secret is present.

### Out of scope for v0.1, on purpose

- Cross-zone routing (LibRover plug-in)
- Curated guide files
- Auto-pick-up next quest
- Class / race / faction branching
- Sound cues, progress bars, localization
- The full Cairn-Gui-2.0 quest panel (deferred to v0.2)
