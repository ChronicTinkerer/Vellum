# Changelog

All notable changes to Vellum are recorded here. The convention is
sequential integer build numbers, one increment per `.dev/release.ps1`
run. Higher numbers are newer.

The format is loosely based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
