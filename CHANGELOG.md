# Changelog

All notable changes to Vellum are recorded here. The convention is
sequential integer build numbers, one increment per `.dev/release.ps1`
run. Higher numbers are newer.

The format is loosely based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **Zygor-style two-window redesign, Phase 1 (skeletons).** Two new files in the Zygor shape, both built on `Cairn-Gui-2.0`:
  - **`HomeWindow.lua`** — the launcher. 720x480 Window with a top `TabGroup` (Home / Active / Recent), a left sidebar (search `EditBox` at top, 5 categories as ghost buttons -- Leveling / Zone / Dailies / Search / Favorites -- and an Options button at the bottom), and a 2x2 placeholder tile grid on the Home tab (Guides History / Suggested Guides / Level Tracker / Gold Tracker, each with a heading + muted body + "See more >" ghost button). Active and Recent tabs are stub panes with placeholder text. Persists position to `db.profile.home.{x, y, selectedTab, sidebarSelected}`.
  - **`StepWindow.lua`** — the per-guide step viewer. 460x540 Window with a per-quest `TabGroup` (placeholder "Quest 1" tab + inert "+" tab), a step counter row inside each tab pane (`<` / Step N / M / `>` / Refresh) with prev/next buttons that scroll a local stepIndex, and a `ScrollFrame` body with three placeholder bullet rows (heading + body + meta line; the active row gets a `> ` prefix as a stand-in for the red left-bar Phase 4 will paint). First-open is offset +240px right of `UIParent` center so the two windows don't overlap. Persists position to `db.profile.stepWindow.{x, y, tabs, activeTab}`.
- **Slash routing** (`Core.lua`): bare `/vellum` now toggles the Home launcher (Zygor-style entry point); `/vellum home` is the explicit alias; `/vellum guide [id|name]` toggles the Step viewer or opens it focused on a specific quest. `/vellum help` still prints the full subcommand list.
- **`db.profile.home` and `db.profile.stepWindow` defaults** alongside the existing `db.profile.panel`. Existing profiles get the new keys lazily on first window open (defaults aren't retroactive per the established Cairn.DB contract).

### Removed

- **`Panel.lua`** retired after Phase 1 visual review approval. Its three tabs (Log / Zone / Search) are subsumed by the Home tile dashboard + sidebar categories in `HomeWindow.lua`. The `ns.Window` back-compat shim it carried for v0.1 callers moves into `HomeWindow.lua` as a tiny redirect (`Show` / `Hide` / `IsShown` -> Home; `SetText` / `Center` are no-ops since Phase 3's StepWindow owns the per-quest header).
- **`/vellum panel`** subcommand removed. The new entry points are bare `/vellum` (toggles Home), `/vellum home` (alias), and `/vellum guide [id|name]` (Step viewer).
- **`/vellum stop`** no longer hides Panel; it now hides StepWindow instead, matching the new window topology.
- **Panel.lua's Follower auto-show wire** removed (it auto-popped the panel on `Follower:Set` and pushed the current quest title into the panel header). Phase 3 will rebuild this on `StepWindow` once the Follower is multi-quest. Until then, `/vellum follow X` runs the arrow without auto-opening any window.

### Added (Phase 2: Home dashboard live)

- **`HomeData.lua`** — new module that owns the saved-variable state behind the four dashboard tiles. Subscribes to `Cairn.Events`:
  - `PLAYER_LOGIN` snapshots `GetMoney()` into `gold.lastSeen` so the first `PLAYER_MONEY` produces a real delta rather than counting the whole balance as today's earnings.
  - `PLAYER_MONEY` diffs current vs `lastSeen`, accumulates into `gold.todayDelta` / `gold.weekDelta`, rolls them over on day / week change (`%Y-%m-%d` / `%Y-%U` keys).
  - `QUEST_TURNED_IN(questID)` marks the most recent matching `guideHistory` entry's `completedAt`.
  - `TIME_PLAYED_MSG(totalSec, _)` captures `totalAtLogin` + `sessionStartGameTime` for live "session played" computation.
  - Wraps `ns.Follower.OnChange` so a new followed `questID` pushes a `guideHistory` entry (cap 50, dedupe at head).
  - Public API: `PushHistoryEntry / MarkHistoryComplete / GetHistory / GetGold / GetTimePlayed / GetFavorites / IsFavorite / ToggleFavorite / OnChanged`.
- **`HomeWindow.lua` rewrite** — the layout is the same Zygor shape but now everything is wired:
  - **Sidebar categories swap the main pane.** `Dashboard / Leveling / Zone / Dailies / Search / Favorites`. Each category has its own renderer; sidebar buttons call `setSidebarCategory(id)` which clears the main pane's tracked widgets and re-renders.
  - **Sidebar search box filters the active category list.** Lives in `sidebarState.needle`; every category renderer applies `matchesNeedle(qid, label)` to its row filter. Independent of the dedicated "Search" category which is full-catalog free-text.
  - **Four live dashboard tiles** (when Home top tab + Dashboard sidebar):
    - Guides History: top 3 entries from `HomeData.GetHistory(3)` with relative-time labels (`5m ago`, `2h ago`, `3d ago`); "See more >" routes to the Recent top tab.
    - Suggested Guides: top 3 LibCodex `Quests:AllRaw()` entries filtered to current `mapID` + faction side + level within +/- 5; "See more >" routes to the Zone sidebar category.
    - Level Tracker: `UnitLevel("player")` + session played + total played from `HomeData.GetTimePlayed()`.
    - Gold Tracker: today / week deltas from `HomeData.GetGold()` formatted as `1g 23s 45c`.
  - **Active top tab**: lists the currently followed quest from `ns.Follower.Get()` with title + objective text. Click row to re-follow + open StepWindow. Will become a list (one row per followed quest) in Phase 3.
  - **Recent top tab**: scrollable list of all `guideHistory` entries with relative-time + "done" markers. Click row to re-follow + open StepWindow.
  - **Refresh-on-data-change.** `HomeData.OnChanged` and `Follower.OnChange` both feed a `refreshIfVisible()` callback that re-renders whichever pane is currently visible.
- **`db.profile.home` schema additions**: `guideHistory` (capped list of `{questID, title, followedAt, completedAt, mapID}`), `gold` (`{dayKey, weekKey, todayDelta, weekDelta, lastSeen}`), `favorites` (`{[questID] = true}` set), `timePlayed` (`{totalAtLogin, sessionStartGameTime}`). Default `sidebarSelected` is now `"dashboard"` so first-open shows the tile grid.
- **Dashboard quest rows route via `followAndOpen(qid)`** which calls `ns.Follower.Set(qid)` then `ns.StepWindow.OpenForQuest(qid)`. (Phase 3: changes to `ns.Follower.Follow(qid)` for additive multi-quest semantics.)

### Changed

- **`Arrow.lua` rotating compass needle is a Material Symbols glyph.** The compass pointer was Blizzard's `Interface\Minimap\MinimapArrow`. It's now a bundled `Vellum/Assets/arrow_pointer.tga` (128x128 RGBA) generated at design time from Material Symbols `navigation` (filled variant) -- the canonical "you are facing this way" paper-plane / compass-needle triangle. (An earlier bake used `arrow_shape_up` which read more as "stylized house"; switched to `navigation` after visual review.) White pixels on transparent background so `SetVertexColor` keeps tinting it green-at-distance / wax-red-on-approach / muted-sepia for low-confidence `codex-zone` sources. Falls back to `MinimapArrow` if the asset is missing.
- **`Arrow.lua` brass ring is also a Material Symbols glyph.** The ring around the parchment disc was using `Interface\Minimap\MiniMap-TrackingBorder`, which has calendar / tracking-icon notches baked in and rendered visibly off-center when used standalone. Replaced with a bundled `Vellum/Assets/ring.tga` (128x128 RGBA) baked from Material Symbols `circle` (outlined default variant) -- a clean centered ring. Tinted brass-gold via `SetVertexColor(0.90, 0.70, 0.25, 1)`. Falls back to `Interface\Common\common-iconframe` if missing.
- **Why this rendering route in general:** WoW renders fonts via `FontString` and `FontString:SetRotation` doesn't exist (fonts can't rotate). The rotating compass + the ring both need to be Textures, so Material Symbols glyphs are pre-rendered to TGAs at design time rather than referenced as live fonts. ImageMagick handles the SVG-to-TGA pipeline; the SVGs are pulled from Google Fonts' static endpoint (`https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/<glyph>/<variant>/48px.svg`) with `fill="white"` injected so vertex coloring works. Pipeline: `convert -background none -density 300 in.svg -resize 128x128 PNG32:tmp.png && convert tmp.png -compress none -alpha on -define tga:image-origin=top-left TGA:out.tga`. The `-define tga:image-origin=top-left` flag is load-bearing -- without it, ImageMagick writes bottom-up TGAs (image_descriptor bit 5 = 0) and WoW renders the texture vertically flipped, so a "point-up" arrow asset shows up "point-down" on the compass and rotation appears 180-deg-opposite.

### Added (Phase 3A: quest-engine foundations)

- **`Follower.lua` refactored to an explicit state machine.** The legacy single-quest API (`Set` / `Clear` / `Refresh` / `Get` / `OnChange`) is unchanged; underneath, `Refresh()` now calls a new pure function `Follower.ComputeState(questID)` and copies its output. The state machine has six explicit states surfaced as `Vellum.Follower.STATES`:
  - `NOT_IN_LOG` -- catalog entry with known giver coords; player doesn't have it
  - `OBJECTIVE` -- in log, working an objective; record carries `objectiveIndex` + `objectiveText` + resolved coords from `Locator.ResolveObjective`
  - `READY_TO_TURNIN` -- `IsComplete` (or all objectives report finished); record carries the turn-in coords from `Locator.ResolveTurnIn`
  - `DONE` -- `IsQuestFlaggedCompleted` returns true (history)
  - `ABANDONED` -- reserved for future explicit handling
  - `UNKNOWN` -- not in log, not in catalog with usable coords
  Live state record now also exposes `engineState` so callers can see "is this NOT_IN_LOG vs OBJECTIVE" without a separate lookup.
- **`Waypoint.lua`** -- new generator. `Waypoint.For(questID)` maps a state record to one of three waypoint types (`PICKUP` / `OBJECTIVE` / `TURNIN`) with location + render-ready label. `Waypoint.ForMany(questIDs)` runs it over a list and skips nil results. `Waypoint.IsActionable(wp)` returns true if the waypoint has usable coords (the route planner uses this to filter out catalog entries without a known giver). DONE / ABANDONED / UNKNOWN states produce nil (no waypoint).
- **`Vellum.toc`** loads `Waypoint.lua` between `Follower.lua` and `Arrow.lua`.
- This is **Phase 3A only**: foundations for the route planner, no UI changes yet, no solver. Phase 3B adds the candidate enumerator + TSP solver. Phase 3C wires the engine to Arrow + StepWindow + HomeWindow.

### Notes

- **Phase 4 next**: Sidebar Options gear opens a settings panel for radius / mode / debounce / pin; same-NPC waypoint bundling; soft recalc on player movement past a threshold; per-waypoint Complete-row strikethrough animation.

### Fixed (Phase 3D)

- **Kill-counter progress (e.g. "Wolves slain: 3/8" → "4/8") now propagates to the StepWindow.** The route signature was `(type|questID|objIdx|source)` -- progress within the same objective changed `objText` but not the sig, so `OnRouteChanged` never fired and the UI didn't refresh on `UNIT_QUEST_LOG_CHANGED("player")`. Sig now includes `objText`. Side effect: when objText is the only thing that changed, route position is unchanged but subscribers re-render -- which is exactly the intent.
- **"Arrow stuck on the quest giver after accept"** -- `Locator.ResolveObjective` had a fallback layer (between `codex-npc` and `codex-zone`) that returned the giver's coords when no objective-specific data could be resolved. After accepting a quest, if Blizzard's `GetNextWaypoint` returned nothing AND LibCodex had no `QuestPOI` for objective 1 AND the objective text didn't parse a known NPC name, the engine pointed the arrow back at the giver -- exactly where the player had just been standing. Removed that fallback. The giver fallback stays in `ResolveTurnIn` (sometimes the giver IS the turn-in for short quests).
- **"Arrow disappears after accept"** -- removing the giver fallback exposed a related issue: `questZoneFallback` relies on `C_QuestLog.GetQuestUiMapID(questID)` which often returns nil for freshly accepted quests until the local log syncs. When that returned nil, the chain ran out of layers and the waypoint got filtered as `missing`. `questZoneFallback` now has a backup: if `GetQuestUiMapID` is nil, fall through to the catalog entry's `mapID` (LibCodex always knows the zone where the giver is). Coords are still zone-center `(0.5, 0.5)`, NOT the giver's exact x/y -- pointing at the giver's coords sends the player backward, but pointing at the zone middle is roughly forward.

### Fixed (Phase 3D-2: critical schema mismatch with LibCodex)

- **Vellum was silently ignoring most LibCodex catalog data.** LibCodex's bundled quest rows store coords inside a `q.locations` LIST of `{mapID, x, y, npcID, point}` records where `point` is `"start"` (giver), `"end"` (turn-in), `"requirement"` (objective target), or `"sourcestart"` / `"sourcerequirement"` (source-tagged variants). Vellum's Locator and Follower read flat `q.mapID / q.x / q.y` fields that **only exist on runtime-added entries** (via LibCodex's `Quests:AddFromAPI`). Bundled rows never have flat coords, so all the layer checks like `if q and q.mapID and q.x and q.y` returned false -- the catalog data was unreachable.
- Concrete example: quest **28763 ("Beating Them Back!")** has 6 location records in the bundled catalog including the giver at `(12, 0.480, 0.420)`, the turn-in at the same coords, and the objective requirement at `(12, 0.474, 0.400)` (NPC 49871). All of that was invisible to Vellum because the resolver checked the wrong field shape.
- Fix: three new helpers in `Locator.lua` -- `codexGiverFromLocations`, `codexTurnInFromLocations`, `codexObjectiveFromLocations` -- that walk `q.locations` and pick the entry matching the requested `point` type, preferring records whose `mapID` matches the player's current zone (some quests are duplicated across map variants, e.g. the Cataclysm-revamped Elwynn at mapID 6170 vs the original at 12). Same helper logic added to `Follower.ComputeState` for the NOT_IN_LOG branch and to `RoutePlanner.GatherCandidates` for the spatial filter.
- Resolver chain updates:
  - `ResolveObjective`: new layer `codex-locations` between `codex-npc` and `codex-zone` (objective-target coords from `point="requirement"`).
  - `ResolveTurnIn`: new layers `codex-locations-end` (turn-in coords from `point="end"`) and `codex-locations-start` (giver coords from `point="start"`, used as a turn-in fallback for short quests).
  - `questZoneFallback`: now also reads `q.locations[].mapID` to find a known zone when `GetQuestUiMapID` returns nil and flat `q.mapID` doesn't exist.

### Added (Phase 3D: pin support)

- **`RoutePlanner.Pin(questID)` / `RoutePlanner.Unpin()` / `RoutePlanner.GetPinned()`.** A pinned quest is forced to position 1 in the route after the NN+2-opt solve, regardless of distance. `applyPin(route, qid)` runs in `Recompute` after the solver and swaps the matching waypoint to the head if found. If no waypoint exists for the pinned questID (e.g. it was just turned in), pin is a no-op until the matching event handler clears it.
- **Auto-pin on `QUEST_ACCEPTED`.** A newly accepted quest replaces any prior pin and becomes `route[1]` after the next debounced recalc. Addresses the "I accepted Q but the arrow stayed pointing at the previously-closest waypoint" symptom: the closest-first heuristic was correct by design but didn't match user intent. With auto-pin, the just-accepted quest takes priority.
- **Auto-unpin on `QUEST_TURNED_IN(qid)` / `QUEST_REMOVED(qid)`** for the pinned questID. After the pin clears the planner reverts to closest-first picking.
- **`/vellum follow X` now pins** instead of just mutating `Follower.state`. `/vellum stop` unpins + clears Follower + hides StepWindow + stops Arrow.
- **Pin persists across `/reload`** via `db.profile.engine.pinned`. Quests are character-bound so per-character storage is correct.

### Changed (Phase 3C: planner drives the UI)

- **`Arrow.lua` is now driven by the route planner.** Removed the file-scope `ns.Follower.OnChange` wire that called `Arrow.Track` from the legacy single-quest follower's state. Replaced with `ns.RoutePlanner.OnRouteChanged`: whenever the route signature changes, the arrow re-targets to `route[1]`'s coords with a label like "Pick up: Wolves of the Wood" / "Wolves of the Wood -- Slain: 0/8" / "Turn in: Wolves of the Wood". Empty route -> `Arrow.Stop()`. The planner's existing PLAYER_ENTERING_WORLD subscription seeds the route on login.
- **`StepWindow.lua` rewritten as the route viewer.** Dropped the per-quest TabGroup and the placeholder bullets. The window is now a single scrollable list of every waypoint in the planner's current route. Active row (`route[1]`) bolded with a `>` prefix; sub-rows show the objective text (when type=OBJECTIVE) and a per-row distance (`+200 yd`) plus the resolution source (`blizzard` / `codex-poi` / etc.). Header summarizes "N waypoints, X yd total." Auto-refreshes on `OnRouteChanged`.
- **`HomeWindow.lua` Active tab shows the route summary.** Replaced "currently followed quest" rendering with a compact list of the first 8 waypoints + total distance. Each row clickable to open the Step viewer (legacy `followAndOpen`; will become "pin this waypoint" later). Auto-refreshes on `OnRouteChanged`.
- **`/vellum follow X` no longer drives the arrow.** It still mutates `Vellum.Follower.state` for any consumer that reads it, but the arrow is now the planner's responsibility. To get the arrow on a specific quest, accept it (it'll appear in the route as an `OBJECTIVE` waypoint and the planner will pick it as `route[1]` if it's nearest). A future "pin" feature in `RoutePlanner` will make manual override possible.

### Visual review checklist

After `/reload`, verify each of these:

1. **Arrow points somewhere on login.** The route planner runs on `PLAYER_ENTERING_WORLD`; if you have any quests in your log or pickable nearby, `route[1]` should be a real waypoint and the compass needle points at it.
2. **Accept a new quest -> arrow updates within ~250ms.** The recalc bus debounces. Watch the arrow re-target.
3. **Turn in a quest -> arrow advances to the next waypoint** (the closest remaining).
4. **`/vellum` opens Home; Active tab shows the route summary.** Click a row to open the Step viewer.
5. **Step viewer shows the full route as a scrolling list.** First row bolded with `>`. Distance labels read sensibly.
6. **`/vellum follow X` no longer redirects the arrow** (this is intentional; pinning lands later). The Follower.state still mutates for legacy consumers.
7. **Toggle in `Vellum.RoutePlanner.SetMode("completionist")` from Forge_Console**: route should expand to include all in-zone catalog quests.
8. **The Phase 3B diagnostic (`vellum_phase3b_planner.lua`) still passes** -- it's a regression check.

### Added (Phase 3B: route planner)

- **`RoutePlanner.lua`** -- new module. Surveys candidate quests (in-log + nearby catalog quests filtered by faction / level / map / radius), runs `Waypoint.For` over them, drops anything `IsActionable` rejects, then solves a constrained TSP via:
  1. **Nearest-neighbor** seed starting from the player's world position.
  2. **2-opt** improvement: tries reversing every `[i..j]` segment of the tour, accepts swaps that reduce total game-world distance. Caps at 8 passes for safety.
  3. **Distance metric**: pure euclidean over `C_Map.GetWorldPosFromMapPos` continent coords. Cross-continent waypoints get distance = `math.huge` so they're routed last (effectively excluded).
  Public API: `GetRoute()`, `Recompute()`, `GetCandidates()`, `GetMode/SetMode("radius"|"completionist")`, `GetRadius/SetRadius(yards)`, `OnRouteChanged(fn)`.
- **`db.profile.engine` schema** -- `mode` ("radius" | "completionist"), `radius` (default 1500 game-yards), `maxWaypoints` (50), `debounceMs` (250). The planner reads these on every Recompute; SetMode / SetRadius mutate them and trigger an immediate recalc. Persisted across `/reload`.
- **Recalc bus with debounce** -- subscribes to `QUEST_ACCEPTED` / `QUEST_REMOVED` / `QUEST_TURNED_IN` / `QUEST_LOG_UPDATE` / `UNIT_QUEST_LOG_CHANGED("player")` / `ZONE_CHANGED_NEW_AREA` / `PLAYER_LEVEL_UP` / `PLAYER_ENTERING_WORLD`. Trailing-edge debounced via `C_Timer.NewTimer` so a `QUEST_LOG_UPDATE` storm coalesces into one Recompute.
- **Route signature change detection** -- after Recompute, the new route's signature `(type|questID|objIdx|source)` is compared to the previous; subscribers fire only if changed. Prevents pointless UI churn when a recompute lands the same route.
- **No UI changes yet.** Phase 3C (next) wires the planner to Arrow + StepWindow + HomeWindow. For now you can probe via Forge_Console: `Vellum.RoutePlanner.Recompute()` then iterate `Vellum.RoutePlanner.GetRoute()`.
- **Phase 4 polish:** active-step red left-bar in StepWindow, tab-switch animations, keyboard nav (Tab cycles tabs, arrows step within a list), Cairn.Settings panel for the [Options] sidebar button, favorite-star toggle on quest rows.
- **`db.profile.panel`** stays in defaults for now (harmless leftover; will be cleaned on the next schema migration). Existing `panel.x/y/selectedTab` values are no longer read by anything.

## [3] — Panel.lua redesign + drag-position persistence (2026-05-08)

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
