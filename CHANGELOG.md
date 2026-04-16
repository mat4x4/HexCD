# HexCD Changelog

## v1.6.2

### Per-bar visibility toggles
- Each tracker bar now has its own "Show this bar" checkbox in Settings → Trackers: Personal Defensives, External Defensives, Utility, Healing CDs, Offensive CDs, Crowd Control
- Bars hide immediately on toggle (no 0.25s wait) via `PCD:RefreshVisibility()`
- Kicks and Dispels already had enable toggles — unchanged

### Difficulty mapping fix
- Fixed a spurious "No plan for difficulty 15, using difficulty 4 plan" warning that fired on every Heroic raid pull. WoW sends difficultyID=15 (Heroic Flex), plans use internal ID 4 (Heroic) — the comparison was in different namespaces. Now maps WoW's ID before comparing via `Config:MapDifficulty()`

### PlanData export path fix
- CD plan exports now correctly target `addons/HexCD_Reminder/PlanData.lua` (the addon that actually loads plans). Previous exports went to `addons/HexCD/PlanData.lua` which is never loaded by the .toc. This fixes Maisara Caverns showing "LEGACY (fixed sections)" + "Dynamic planner returned no plan" despite having a fully dynamic plan in the knowledge files.

### Warrior CC visibility
- Shockwave (46968) and Storm Bolt (107570) ungated from `talentOnly` — pre-populate for all warriors regardless of inspection state

### Paladin Divine Protection dedup
- Removed 403876 (Ret variant) from AuraRules Ret Paladin block — was the primary source of duplicate "Divine Protection" icons on Ret paladins. AuraDetector still picks up 403876 live if the talent is actually cast

## v1.6.1

### Kickable-cast TTS gate (Midnight 12.0 nameplate workaround)
- New `CastDetector` module listens to `UNIT_SPELLCAST_*` on hostile nameplates and maintains a per-cast kickable state machine (`START` / `NOT_INTERRUPTIBLE` / `INTERRUPTIBLE` / `STOP` transitions)
- Works around Blizzard's Midnight restriction where nameplate spellIDs arrive as secret-tainted values that survive all known laundering tricks — we can't identify *what* is being cast, but we can track *whether it's kickable right now*
- `KickTracker:CheckAlert` now gates TTS on `CastDetector:HasActiveKickableCast()` (new `kickRequireActiveCast = true` config, default on) — suppresses "ready to kick" spam during idle rotation churn; alerts fire only when there's something to actually interrupt
- KickTracker registers as a CastDetector listener, so a fresh kickable cast on a nameplate also triggers re-check (not just rotation advances)
- Taint-hardened: every field from `UnitCastingInfo` / `UnitChannelInfo` / event payload guarded by `IsSecret` before any arithmetic, `tostring`, or `%s` format — prevents the "tainted by HexCD" 736x error spam seen in early Midnight builds
- DEBUG-level observability of state transitions and gate decisions (`CastDetector: kickable START nameplateN`, `KickTracker: alert allowed/skipped`)

### Paladin Divine Protection dedup
- Removed `403876` (Ret variant) from AuraRules Ret Paladin block — it was the primary source of pre-population alongside baseline `498`, causing Ret paladins to show two identical "Divine Protection" icons
- AuraDetector still picks up `403876` live if the player has the talent and casts it in combat
- `SpellDB.lua`: marked `403876` as `talentOnly = true` so CommSync's secondary pass respects talent cache
- Regression test in `test_prepop_spec_gate.lua` asserts Ret gets exactly one baseline Divine Protection entry

### Warrior CC visibility
- `Shockwave (46968)` and `Storm Bolt (107570)` ungated from `talentOnly` — now pre-populate for every warrior regardless of talent inspection state. The CD only becomes visually active when the spell is actually cast, so untalented warriors see nothing extra

### Debug log readability
- Chat emissions in `DebugLog:Log` now sanitize em-dash `—` → `-` and right arrow `→` → `->` (WoW's default chat font renders these as boxes). The ring buffer and text exports preserve original Unicode
- `CastDetector` at DEBUG level now logs only kickable-relevant events (`START` / `CHANNEL_START` / `INTERRUPTED` / `INTERRUPTIBLE` / `NOT_INTERRUPTIBLE`). Noisy `SUCCEEDED` / `STOP` / `CHANNEL_STOP` / `FAILED` / `DELAYED` events still update the state machine but are gated to TRACE level — cuts M+ pull log volume by ~10x

### Top-parse CD plans
- **Pit of Saron +21**: updated to match the current #1 Resto Druid parse (109k HPS). NS+Convoke macro on every boss pull, Tranq mid-Garfrost (130s) and Ick/Krick opener (25s), zero Tranq on Tyrannus (pure Convoke cycles cover Festering Pulse). Tree of Life dropped entirely.
- **Windrunner Spire +20**: updated to match the current #1 Resto Druid parse (122k HPS). No Tree, no Tranq on Kroluk or Restless Heart, heavy Ironbark/Ursol's Vortex cycling on melee-heavy bosses. Kroluk plan avoids BigWigs anchors (Rallying Bellow has no bar — HP-threshold).

## v1.6.0

### Spec audit (13 classes)
- Full per-spec truth-table audit of SpellDB + AuraRules gating for Midnight 12.0.5 — Druid, Priest, Monk, Paladin, Shaman, Evoker, Death Knight, Demon Hunter, Mage, Rogue, Warlock, Warrior, Hunter
- ~70 spell additions across categories (Touch of Karma, Invoke Xuen, Storm Earth and Fire, Invoke Yu'lon, Restoral, Holy Avenger, Crusade, Fire Elemental, Storm Elemental, Stormkeeper, Feral Spirit, Breath of Eons, Stasis, Tail Swipe, Sleep Walk, Frostwyrm's Fury, Breath of Sindragosa, Summon Gargoyle, Death Pact, Metamorphosis (Havoc), The Hunt, Sigil of Spite, Sigil of Chains, Gorefiend's Grasp, Icy Veins, Mirror Image, Adrenaline Rush, Killing Spree, Deathmark, Dreadblades, Sepsis, Summon Infernal, Demonic Tyrant, Darkglare, Soul Rot, Nether Portal, Recklessness, Bladestorm, Thunderous Roar, Champion's Spear, Call of the Wild, and many more)
- Missing CC sweep: Incapacitating Roar, Typhoon, Mighty Bash, Frost Nova, Dragon's Breath, Blind, Howl of Terror, Mortal Coil, Storm Bolt, Shockwave, Intimidation, Binding Shot, Asphyxiate, Hammer of Justice, Song of Chi-Ji, Wind Rush Totem
- Corrected spec gates: Innervate → Resto-only talent, Survival Instincts → Feral/Guardian only, Aura Mastery → Holy only, Pain Suppression/Ironbark → EXTERNAL_DEFENSIVE, BoP/BoSacrifice/Lay on Hands → EXTERNAL_DEFENSIVE
- Per-spec category override for hybrid spells (Avenging Wrath → HEALING for Holy, OFFENSIVE for Ret/Prot)
- Removed stale entries: Flourish, Nature's Swiftness (cast-time modifier), Feint (rotational <60s), Mind Bomb (no longer in game), Ancestral Guidance (removed in 11.1.0)

### Cast detection & CD stamping
- SpellDB-backed synthetic cast fast-path: any tracked spell with `cd > 0` auto-registers a stamping rule, eliminating the gap for CC and audit-added spells without explicit AuraRules entries
- Nameplate-aura CC stamping (MiniCC-style): party-cast CCs on enemy nameplates stamp party CDs, providing a redundant source when `UNIT_SPELLCAST_SUCCEEDED` delivers a redacted `spellID=0` under Midnight's sandbox
- Dynamic class-based kick resolution: redacted kick spellIDs fall back to `ResolveKickSpell(class, spec)` for correct CD stamping
- CooldownTracker talent-adjusted base CD on first cast via `DurationModifiers` (e.g. Cenarius' Guidance reduces Convoke base from 120s → 60s at first observation)
- Cast fast-path includes talent-gated rules via SpellDB fallback (the cast event itself proves talent ownership)

### Pre-pop gating
- `Util.PlayerHasSpell` cascades 4 APIs (`IsPlayerSpell`, `IsSpellKnown`, `FindSpellBookSlotBySpellID`, `C_SpellBook.IsSpellBookEntry`) to catch legacy-ID talents that the C_Traits tree doesn't map directly
- Talent-gated pre-pop: check player via `PlayerHasSpell`, party via TalentCache; prune path mirrors the same logic to avoid re-adding ghosts
- Diagnostic DEBUG log: `CommSync: talent check <Name> (<id>, <category>) → PASS/skip` for every class-tree CC evaluation

### Auto-enroll improvements
- KickTracker + DispelTracker auto-enroll now fires in raids too, not just parties
- Bidirectional stale detection: re-enroll when any rotation name is gone from the group OR when a current kicker/dispeller is missing from the rotation
- Cap auto-enroll at 5 members per rotation
- NPC follower support: Exile's Reach / follower dungeons now properly enroll followers who cast kicks/dispels
- Clear stale rotation when transitioning to groups with no valid kickers/dispellers (prevents "rotation full" lockouts)
- Auto-enrolled kicker order: sorted lowest-CD first
- Mid-combat auto-add triggers HIDDEN → ACTIVE transition so the bar shows up even when combat started with an empty rotation

### Other
- CCTracker + CCDisplay removed — the CC bar now uses the standard PartyCDDisplay floating-bar category driven by `CommSync.partyCD`
- Category audit test covers 170+ curated (id, expected-category) pairs plus invariants (every category non-empty, ≥60s rule for defensive/healing/offensive with grandfathered exceptions)
- Corrected cooldowns: Invoke Yu'lon 180 → 120, Mirror Image 120 → 90, Recklessness 90 → 300, Bestial Wrath 90 → 30, Tail Swipe/Wing Buffet 90 → 180, Survival of the Fittest 180 → 90, Convoke base 60 → 120 (CG talent reduces to 60 via DurationModifiers)
- Taint-safe ordering in nameplate aura scan — guards secret-value spellIDs before arithmetic comparisons

## v1.0.0
- **Party & Raid CD Tracking** via SendAddonMessage — works under Midnight 12.0 addon restrictions
- Personal defensives anchored to unit frames (Danders, Cell, ElvUI, Blizzard)
- Floating bars for Ranged Party CDs, Stacked Party CDs, Healing CDs
- Comprehensive spell database: defensives, immunities, healing CDs, interrupts, dispels
- Per-spell enable/disable with icon-based GUI
- Dispel rotation tracker with overlay and cross-player sync
- Kick rotation tracker with overlay and cross-player sync
- CD Reminder with timer bars and TTS announcements (HexCD_Reminder)
- Boss CD plans with BigWigs bar integration and phase drift correction
- M+ dynamic trash CD planning based on pull composition
- Supports Dander Frames, Cell, ElvUI, Blizzard party/raid frames
