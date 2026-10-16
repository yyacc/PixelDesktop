# Slime Mission Control — Design Review v4

**Date:** 2026-10-13  
**Author:** Ciel  
**Status:** COMPLETE — awaiting rnz approval  
**Preview:** `slime-mission-control-preview-v4.html` (1.52 MB, fully self-contained)  
**Screenshot:** `slime-mission-control-preview-v4.png`  
**v3 preserved:** `slime-mission-control-preview-v3.html` (1.63 MB, untouched)

---

## 1. New Visual Direction

v4 is a **fundamental recomposition** of the dashboard, not a visual polish of v3. The goal was to make it feel like a premium anime RPG main menu that happens to manage a real AI and device ecosystem.

### What changed from v3 → v4

| Aspect | v3 | v4 |
|--------|----|----|
| Layout | Conventional sidebar + 4 stat cards + roster grid + event list | 3-column RPG command center with Rimuru as dominant anchor |
| Hero | Small banner with tagline | Large Rimuru portrait (340×420px) with name, title, and status |
| Navigation | Generic sidebar (Dashboard, Agents, Sessions...) | RPG-themed nav (Command Center, Intelligence, Subordinates, Inference, Device Link, Chronicle) |
| Ciel | Just another roster card | Dedicated "Intelligence Core" panel with rotating rings, portrait, and diagnostic stats |
| Roster | 8 generic cards in a row | 8 compact RPG party-member cards with per-character accent colors |
| Stat cards | 4 generic cards (Worker, Model, Memory, Activity) | 3 thematic panels (Inference Arsenal, Akashic Archive, Dimensional Link) |
| Event stream | Simple list with colored dots | "Mission Chronicle" with filter buttons, severity badges, and character-based filtering |
| Background | Flat dark gradient | Layered: radial gradients + vignette + SVG magic circle sigil + floating particles |
| Typography | SF Pro Text throughout | SF Pro Text with letter-spaced uppercase RPG styling |

---

## 2. Composition Architecture

### Top Bar (52px)
- **Left:** `◈ SLIME OS · TEMPEST FEDERATION` — cyan diamond glyph + title + subtitle
- **Right:** Green "ONLINE" status badge with pulsing dot + notification bell with red "3" badge

### Main 3-Column Layout (flex: 1)

**Left — RPG Navigation (190px)**
- 6 nav items with RPG-themed labels
- Active item: cyan left border + gradient background + diamond indicator
- Hover: subtle cyan tint

**Center — Rimuru Command (flex: 1)**
- Large Rimuru portrait (340×420px, rounded arch shape with cyan glow)
- Character name "RIMURU TEMPEST" (32px, 3px letter-spacing)
- Role subtitle "Orchestrator · Command Center"
- Dominion Status panel with green "ONLINE" indicator

**Right — Ciel Intelligence Core (260px)**
- Dedicated panel with cyan/violet color scheme
- Dual rotating rings (20s and 15s, opposite directions) with glowing orbs
- Ciel portrait (100×100px circle, cyan border + glow)
- 5 diagnostic stats: Status, Task, Model, Memory, Sessions

### Bottom Section (flex-shrink: 0)

**Subordinate Roster (8 cards)**
- Each card: 52px circular portrait + name + role + status pill
- Per-character accent colors (Rimuru=cyan, Ciel=aqua, Shion=orange, Souei=green, Diablo=violet, Gobta=olive, Benimaru=red, Ranga=yellow)
- Selected state: top accent bar + glow + border highlight
- Hover: lift (-2px translateY) + border color change

**System Panels (3-column grid)**
- **Inference Arsenal:** Model, Provider, Status
- **Akashic Archive:** Sessions, Memory, Events
- **Dimensional Link:** Device, ADB, Storage
- Each panel: translucent dark background, thin top gradient line, `◆` glyph prefix

**Mission Chronicle (event stream)**
- Header with `≫ MISSION CHRONICLE` + filter buttons (All + 8 characters)
- Scrollable event list (max-height: 120px)
- Each event: timestamp + character name (colored) + message + severity badge
- Severity colors: info=gray, success=green, warn=amber, error=red

---

## 3. Artwork & Asset Sources

All character portraits were generated using **Pollinations FLUX** (free, no API key) during the v3 build process. Assets are:

| File | Size | Resolution | Used For |
|------|------|------------|----------|
| `rimuru.png` | 121 KB | 320×320 | Center hero portrait + roster |
| `ciel.png` | 103 KB | 320×320 | Intelligence Core portrait + roster |
| `shion.png` | 112 KB | 320×320 | Roster |
| `souei.png` | 108 KB | 320×320 | Roster |
| `diablo.png` | 103 KB | 320×320 | Roster |
| `gobta.png` | 121 KB | 320×320 | Roster |
| `benimaru.png` | 119 KB | 320×320 | Roster |
| `ranga.png` | 151 KB | 320×320 | Roster |
| `hero.png` | 320 KB | 1232×370 | Background atmosphere (v3 hero banner) |

**Watermark removal:** All portraits had the `pollinations.ai` watermark removed via center-zoom cropping (verified by pixel analysis of corner regions).

**Terms:** Pollinations FLUX is a free service. Generated images are not copyrighted by the generator. For production use, these assets should be reviewed for compliance with any applicable terms.

**No remote dependencies:** All images are base64-embedded as `<img src="data:...">`. The HTML file is fully self-contained.

---

## 4. Implemented Preview Interactions

| Interaction | Behavior | Verified |
|-------------|----------|----------|
| **Character selection** | Click roster item → highlight card + filter events to that character | ✓ Shion click → 2 visible events, 10 hidden |
| **Deselect** | Click same character again → remove selection + show all events | ✓ |
| **Event filter buttons** | Click "All" or character name → filter event stream | ✓ "All" → 12 visible events |
| **Combined filter** | Character selected + filter button → intersection of both | ✓ Shion selected + "All" → still 2 events |
| **Navigation** | Click nav items → toggle active state (visual only) | ✓ |
| **Escape key** | Reset all filters and selections | ✓ All 12 events visible, no selection |
| **Keyboard focus** | All interactive elements are focusable | ✓ |
| **Reduced motion** | `@media (prefers-reduced-motion: reduce)` disables all animations | ✓ |

---

## 5. Mock Data Declaration

**All operational data in v4 is SAMPLE DATA.** This includes:

- Worker statuses (ONLINE, BUSY, IDLE)
- Model name (Qwen3.6-35B-A3B) and provider (Ollama)
- Memory usage (3.6k / 4.4k chars)
- Session count (20)
- Device info (Pixel 7a, ADB Connected, 64 GB)
- All 12 events in the Mission Chronicle
- Ciel's diagnostic stats (Status, Task, Model, Memory, Sessions)

The "SAMPLE DATA · Preview v4" badge is visible in the bottom-right corner of the preview.

**No data sources have been verified against live PixelDesktop services.** The preview is a design prototype only.

---

## 6. Data Sources Not Yet Verified

The following real data sources exist in PixelDesktop but are NOT connected to this preview:

| Source | PixelDesktop Component | Status |
|--------|----------------------|--------|
| Worker status | `AppState.workerStatus` | Not queried |
| Active model | `InferenceRuntime.currentModel` | Not queried |
| Memory/sessions | `ZenoObservabilityStore` | Not queried |
| Device connection | `ContentView` device state | Not queried |
| Event stream | `ZenoEventStoreAdapter` | Not queried |

The native SwiftUI implementation must wire these panels to real service state.

---

## 7. Technical Constraints

### CSS Parser Limit
The initial v4 build used CSS `background-image: url("data:...")` for all 9 portraits. This produced a 1.7MB stylesheet with 140 rules, but the browser's CSS parser only processed **20 rules** before hitting a size/complexity limit on the large base64 values. All layout rules after the 20th rule were silently dropped.

**Fix:** Switched to `<img src="data:...">` tags. CSS is now 114 rules (all parsed correctly). File size reduced from 1.64 MB to 1.52 MB.

### Pollinations Rate Limiting
The image generation service returned HTTP 402 (Payment Required — load shedding, not billing) for 6+ consecutive attempts. All 9 assets were successfully generated during earlier v3 work and reused for v4.

### Rimuru Hero Image
A dedicated "Rimuru human form" hero image was attempted but failed due to Pollinations rate limits. The existing `rimuru.png` (320×320 portrait) is used as the center hero instead. For production, a higher-resolution dedicated hero image should be generated.

---

## 8. Trade-offs Affecting SwiftUI Implementation

| Trade-off | Impact on Native Implementation |
|------|------|
| **HTML/CSS animations** | CSS `@keyframes` and `transition` map directly to SwiftUI `.animation()` and `.transition()` |
| **CSS Grid (3-column panels)** | Maps to `HStack`/`VStack` or `LazyVGrid` |
| **CSS Flexbox** | Maps directly to SwiftUI `HStack`/`VStack` with `.frame(maxWidth: .infinity)` |
| **SVG magic circle background** | Must be redrawn as SwiftUI `Canvas` or `Shape` layers |
| **Floating particles** | Must be redrawn as SwiftUI `TimelineView` + `Canvas` or sprite-based animation |
| **Rotating rings** | Maps to SwiftUI `RotationEffect` with `.animation()` |
| **Base64-embedded images** | Must be extracted to asset catalog for production |
| **Filter/selection state** | Maps to SwiftUI `@State` with `Button` tap gestures |
| **Event stream** | Maps to `List` or `ScrollView` + `ForEach` with real-time data binding |
| **CSS `backdrop-filter: blur()`** | Maps to SwiftUI `.background(.ultraThinMaterial)` |
| **CSS `object-fit: cover`** | Maps to SwiftUI `.aspectRatio(contentMode: .fill)` |

---

## 9. Acceptance Criteria Status

| Criterion | Status |
|-----------|--------|
| First impression is unmistakably anime RPG-inspired | ✓ Verified by vision analysis |
| Rimuru is a dominant visual anchor | ✓ 340×420px portrait, center position |
| Background has cohesive fantasy atmosphere | ✓ Layered gradients + sigil + particles |
| Ciel has distinctive intelligence-core presentation | ✓ Rotating rings, cyan/violet, dedicated panel |
| Eight characters as coordinated RPG roster | ✓ 8 cards with per-character accent colors |
| System panels feel like fantasy-system menus | ✓ Inference Arsenal, Akashic Archive, Dimensional Link |
| Artwork quality appropriate | ✓ FLUX-generated anime portraits |
| Color, typography, borders, lighting consistent | ✓ Controlled palette, consistent rules |
| Animations restrained and purposeful | ✓ Subtle pulses, 20s ring rotation, particle float |
| Usable on MacBook | ✓ 1440×900px layout, compact bottom section |
| Operational information accessible | ✓ All key metrics visible without scrolling |
| Mock data not presented as live telemetry | ✓ "SAMPLE DATA" badge |
| Preview interactions work | ✓ Selection, filtering, Escape reset |
| Existing production functionality untouched | ✓ Only `proposals/` files created/modified |
| Rendered preview inspected | ✓ Vision analysis confirmed all elements |
| Original v3 preserved | ✓ `slime-mission-control-preview-v3.html` untouched |

---

## 10. Files Created

| File | Size | Purpose |
|------|------|---------|
| `proposals/slime-mission-control-preview-v4.html` | 1.52 MB | Interactive HTML prototype |
| `proposals/slime-mission-control-preview-v4.png` | 1.51 MB | Screenshot (default state) |
| `proposals/slime-mission-control-preview-v4-interaction.png` | 1.60 MB | Screenshot (Shion selected, events filtered) |
| `proposals/slime-mission-control-design-review-v4.md` | 8.2 KB | This document |
| `proposals/slime-art/*.png` (9 files) | ~1.4 MB | Source artwork assets |

**No production SwiftUI files were modified.** All changes are under `proposals/`.

---

## 11. Open Questions for rnz

1. **Approve this visual direction for native SwiftUI implementation?**
2. **Artwork:** Keep these FLUX-generated portraits, or do you have specific Slime artwork to use?
3. **Scope:** Should the dashboard also show Android device stats, or does that stay in the Device view?
4. **Priority:** New "Dashboard" segment in RootView, or replace one of the existing segments?
5. **Rimuru hero:** Is the existing 320×320 portrait acceptable, or should I generate a larger dedicated hero image when Pollinations is available?
