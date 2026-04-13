# HexCD Changelog

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
