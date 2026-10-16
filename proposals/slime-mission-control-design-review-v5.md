# Slime Mission Control — Design Review v5

**Date:** 2026-10-13  
**Author:** Ciel  
**Status:** COMPLETE — awaiting rnz approval  
**Preview:** `slime-mission-control-preview-v5.html` (1.52 MB, fully self-contained)  
**Screenshots:** `slime-mission-control-preview-1440.png`, `slime-mission-control-preview-1280.png`, `slime-mission-control-preview-1024.png`  
**v3/v4 preserved:** Both untouched

---

## 1. New Visual Direction

v5 is a **complete visual overhaul** from v4, shifting from fantasy-RPG command center to **anime gacha game UI**. The reference direction is *That Time I Got Reincarnated as a Slime: Isekai Memories* and comparable premium anime mobile gacha interfaces.

### What changed from v4 → v5

| Aspect | v4 (Fantasy RPG) | v5 (Gacha Game) |
|--------|------------------|-----------------|
| Overall aesthetic | Ornate medieval fantasy | Clean modern game UI |
| Color palette | Deep navy + gold + cyan | Deep navy + blue + cyan + restrained accents |
| Character presentation | RPG party members | **Gacha unit collection with rarity frames** |
| Rarity system | None | **SSR (gold), SR (purple), R (blue)** with star ratings |
| Rimuru presentation | Large portrait with name/title | **Featured unit with FEATURED badge, level, rarity stars** |
| Ciel presentation | Intelligence core with rotating rings | **Same concept, refined with cleaner ring styling** |
| Roster cards | Generic cards with accent colors | **Gacha cards with rarity borders, PWR stats, star ratings** |
| Stat panels | Inference Arsenal, Akashic Archive, Dimensional Link | **Inference, Memory, Device Link** (cleaner naming) |
| Event stream | Mission Chronicle with filters | **Mission Log with filter chips** |
| Background | Layered gradients + SVG magic circle + particles | **Subtle grid + gradient + particles** (no ornate sigil) |
| Navigation | Command Center, Intelligence, Subordinates... | **Command, Intelligence, Units, Inference, Device, Log** |
| Typography | Heavy letter-spacing, uppercase RPG | **Cleaner, more compact game UI typography** |

---

## 2. Gacha Game UI Design Language

### Rarity System
- **SSR (Super Super Rare):** Gold border (`rgba(251,191,36,0.5)`), 5 stars, gold glow
- **SR (Super Rare):** Purple border (`rgba(167,139,250,0.45)`), 4 stars, purple glow
- **R (Rare):** Blue border (`rgba(96,165,250,0.3)`), 3 stars, no glow

### Character Cards
Each card displays:
- Circular portrait with rarity-colored border
- Star rating (★★★★★) below portrait
- Rarity badge (SSR/SR/R) in top-right corner
- Character name
- Role/title in character-specific accent color
- PWR (power level) value
- Status pill (ONLINE/BUSY/IDLE)

### Featured Unit (Rimuru)
- Large portrait (300×380px) with rounded corners and blue glow
- **FEATURED** badge (gold gradient, top-left corner)
- Character name, role, and compact stat block
- Level, rarity stars, and status

### Ciel Intelligence Core
- Dedicated right-side panel with cyan/blue color scheme
- Dual rotating rings (20s and 15s, opposite directions) with glowing orbs
- Ciel portrait (80×80px circle, cyan border + glow)
- 5 diagnostic stats: Status, Task, Model, Memory, Sessions

---

## 3. Artwork & Asset Sources

### Current Assets (Reused from v3/v4)
All 9 character portraits were generated using **Pollinations FLUX** during v3 development. They are **reused in v5** with CSS styling to fit the gacha aesthetic.

| File | Size | Character | Rarity |
|------|------|-----------|--------|
| `rimuru.png` | 121 KB | Rimuru | SSR |
| `ciel.png` | 100 KB | Ciel | SSR |
| `shion.png` | 109 KB | Shion | SR |
| `souei.png` | 105 KB | Souei | SR |
| `diablo.png` | 100 KB | Diablo | SSR |
| `gobta.png` | 118 KB | Gobta | R |
| `benimaru.png` | 119 KB | Benimaru | SR |
| `ranga.png` | 147 KB | Ranga | SR |

### Art Style Assessment
**The current assets are NOT crisp anime-game renders.** Vision analysis rated them **2/10** for gacha game fit:
- Soft, painterly AI-generated style
- Lacks clean linework and sharp edges
- More "semi-realistic anime" than cel-shaded game art
- Would look out of place alongside official Tensura: Isekai Memories assets

**Recommendation:** Regenerate all character assets with prompts that explicitly request:
- "cel-shaded anime game character render"
- "clean linework, sharp edges"
- "flat colors, no painterly brushstrokes"
- "official anime game art style"
- "Tensura Isekai Memories character art style"

The v5 HTML framework is designed to work with any portrait images — only the `src` attributes need to be updated when new assets are ready.

---

## 4. Implemented Preview Interactions

| Interaction | Behavior | Verified |
|-------------|----------|----------|
| **Character selection** | Click card → highlight + filter events to that character | ✓ Shion click → 2 visible events |
| **Deselect** | Click same card again → remove selection + show all events | ✓ |
| **Filter buttons** | Click "All" or character name → filter event stream | ✓ |
| **Combined filter** | Card selected + filter button → intersection | ✓ |
| **Navigation** | Click nav items → toggle active state | ✓ |
| **Escape key** | Reset all filters and selections | ✓ All 12 events visible |
| **Rarity borders** | SSR=gold, SR=purple, R=blue (2px borders) | ✓ All 8 cards verified via DOM |
| **Responsive layout** | 1440px, 1280px, 1024px widths | ✓ All three tested |
| **Reduced motion** | `@media (prefers-reduced-motion: reduce)` disables animations | ✓ |

---

## 5. Mock Data Declaration

**All operational data in v5 is SAMPLE DATA.** This includes:
- Worker statuses (ONLINE, BUSY, IDLE)
- Model name (Qwen3.6-35B-A3B) and provider (Ollama)
- Memory usage (3.6k / 4.4k chars)
- Session count (20)
- Device info (Pixel 7a, ADB Connected, 64 GB)
- All 12 events in the Mission Log
- Power levels (PWR 65-98)
- Ciel's diagnostic stats

The "SAMPLE DATA · v5" badge is visible in the bottom-right corner.

---

## 6. Responsive Layout

| Width | Body Width | Layout Changes |
|-------|-----------|----------------|
| 1440px | 1424px | Full layout, 300×380px hero portrait |
| 1280px | 1264px | Reduced hero (260×320px), narrower nav (160px), narrower Ciel panel (220px) |
| 1024px | 1008px | Further reduced hero (220×280px), narrower nav (140px), narrower Ciel panel (200px), smaller cards |

All three widths tested and verified via screenshots.

---

## 7. Data Sources Not Yet Verified

| Source | PixelDesktop Component | Status |
|--------|----------------------|--------|
| Worker status | `AppState.workerStatus` | Not queried |
| Active model | `InferenceRuntime.currentModel` | Not queried |
| Memory/sessions | `ZenoObservabilityStore` | Not queried |
| Device connection | `ContentView` device state | Not queried |
| Event stream | `ZenoEventStoreAdapter` | Not queried |

---

## 8. Technical Notes

### CSS Parser Limit (Same as v4)
The HTML uses `<img src="data:...">` tags instead of CSS `background-image` to avoid the browser's CSS parser limit on large base64 values. 114 CSS rules, all parsed correctly.

### Mission Log Scrolling
The event stream has `max-height: 110px` with `overflow: auto`. With 12 events at ~21px each (256px total), the log is scrollable. This is standard behavior for event streams and ensures the bottom section doesn't grow unbounded.

### Asset Embedding
All images are base64-embedded as `<img src="data:...">`. The HTML file is fully self-contained with no external dependencies.

---

## 9. Trade-offs Affecting SwiftUI Implementation

| Trade-off | Impact on Native Implementation |
|------|------|
| **HTML/CSS animations** | Maps to SwiftUI `.animation()` and `.transition()` |
| **CSS Grid (3-column panels)** | Maps to `LazyVGrid` or `HStack`/`VStack` |
| **CSS Flexbox** | Maps directly to SwiftUI `HStack`/`VStack` |
| **Rarity border colors** | Maps to SwiftUI `.border()` with `Color` |
| **Rotating rings** | Maps to `RotationEffect` with `.animation()` |
| **Base64-embedded images** | Must be extracted to asset catalog for production |
| **Filter/selection state** | Maps to SwiftUI `@State` with `Button` tap gestures |
| **Event stream** | Maps to `List` or `ScrollView` + `ForEach` with real-time data binding |
| **CSS `object-fit: cover`** | Maps to SwiftUI `.aspectRatio(contentMode: .fill)` |
| **Responsive breakpoints** | Maps to SwiftUI `@Environment(\.horizontalSizeClass)` or `GeometryReader` |

---

## 10. Acceptance Criteria Status

| Criterion | Status |
|-----------|--------|
| Anime gacha game UI aesthetic | ✓ Clean, dark, game-like interface |
| Rimuru as featured unit | ✓ Large portrait, FEATURED badge, level, rarity |
| Ciel distinctive intelligence core | ✓ Rotating rings, dedicated panel, cyan/blue scheme |
| 8-character roster with rarity frames | ✓ SSR/SR/R borders, stars, PWR stats |
| Deep navy/blue/cyan color palette | ✓ Controlled palette, restrained accents |
| Polished game-menu surfaces | ✓ Clean panels, subtle borders, compact labels |
| No ornate medieval frames | ✓ Removed all fantasy-RPG ornamentation |
| No excessive metallic gold | ✓ Gold reserved for SSR rarity only |
| No Final Fantasy-style menus | ✓ Clean modern game UI |
| No painted fantasy backgrounds | ✓ Subtle grid + gradient only |
| Cohesive game UI (not illustrations on dashboard) | ✓ Unified design system |
| Pixel 7a connectivity accessible | ✓ Device Link panel |
| Ciel status accessible | ✓ Intelligence Core panel |
| Zeno status accessible | ✓ Memory panel |
| Active tasks accessible | ✓ Mission Log |
| Recent events accessible | ✓ Mission Log with filters |
| All 6 sections retained | ✓ Command, Intelligence, Units, Inference, Device, Log |
| Responsive at 1440/1280/1024px | ✓ All three tested |
| v4 preview preserved | ✓ Untouched |
| Production SwiftUI files unchanged | ✓ Only `proposals/` files created/modified |
| Rendered preview inspected | ✓ Vision analysis + DOM verification |
| Character assets assessed | ✓ **NOT crisp anime-game renders — regeneration recommended** |

---

## 11. Open Questions for rnz

1. **Approve this gacha game visual direction for native SwiftUI implementation?**
2. **Artwork regeneration:** Should I regenerate all 9 character assets with cel-shaded anime-game-render prompts? The current assets are painterly and rated 2/10 for gacha fit.
3. **Scope:** Should the dashboard also show Android device stats, or does that stay in the Device view?
4. **Priority:** New "Dashboard" segment in RootView, or replace one of the existing segments?
5. **Rarity assignments:** I assigned SSR to Rimuru/Ciel/Diablo, SR to Shion/Souei/Benimaru/Ranga, R to Gobta. Do you agree with these tiers?

---

## 12. Files Created

| File | Size | Purpose |
|------|------|---------|
| `proposals/slime-mission-control-preview-v5.html` | 1.52 MB | Interactive HTML prototype |
| `proposals/slime-mission-control-preview-1440.png` | 1.37 MB | Screenshot (1440px) |
| `proposals/slime-mission-control-preview-1280.png` | 1.23 MB | Screenshot (1280px) |
| `proposals/slime-mission-control-preview-1024.png` | 1.08 MB | Screenshot (1024px) |
| `proposals/slime-mission-control-design-review-v5.md` | ~10 KB | This document |

**No production SwiftUI files were modified.** All changes are under `proposals/`.
