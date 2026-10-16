# Slime Mission Control — Design Review v7 (Vintage Newspaper Editorial)

**Date:** 2026-10-13
**Author:** Ciel
**Status:** COMPLETE — awaiting rnz approval
**Preview:** `slime-mission-control-preview-v7.html` (1.66 MB, fully self-contained)
**Source:** `slime-mission-control-preview-v6.html` (anime gacha direction — superseded)
**Screenshots:** `slime-mission-control-preview-v7-1440.png`, `slime-mission-control-preview-v7-1280.png`, `slime-mission-control-preview-v7-1024.png`

---

## 1. Direction Change

v7 abandons the anime gacha-game UI direction entirely. The new aesthetic is a **premium vintage newspaper / editorial publication** — think early-to-mid 20th century broadsheet, archival journal, or refined literary magazine printed on slightly aged paper.

This is a complete visual system overhaul: palette, typography, layout structure, borders, spacing, and decorative details all changed. The application remains a functional desktop command center.

---

## 2. Visual System

### Color Palette
| Token | Value | Usage |
|-------|-------|-------|
| `--paper` | `#E8DCC3` | Main background |
| `--paper-light` | `#F0E6D2` | Panel surfaces, selected states |
| `--paper-shadow` | `#D5C3A3` | Depth accents |
| `--ink` | `#29251F` | Primary text, headings, rules |
| `--ink2` | `#62584A` | Secondary text |
| `--ink3` | `#897B67` | Tertiary/metadata text |
| `--rule` | `#A99A80` | Borders, separators |
| `--accent` | `#53604F` | Green accent (selected states, headings) |

### Typography
- **Primary:** Georgia, Times New Roman, serif — masthead, headings, character names
- **Secondary:** SF Mono, Menlo, monospace — metadata, timestamps, status labels, technical info
- **Hierarchy:** 28px masthead → 32px featured name → 11px body → 9px metadata
- **Treatment:** Uppercase + letter-spacing for headings; italic for roles/subtitles

### Layout Structure
- **Masthead:** 3px double-rule header with "SLIME OS" + "Mission Control Edition" + volume/issue metadata
- **Meta bar:** Publication-style metadata (est. date, tagline) under thin rule
- **Main:** 3-column (nav / featured story / Ciel intelligence)
- **Bottom:** Roster → System Panels → Mission Log, separated by double rules

### Decorative Elements
- Subtle paper gradient overlays (radial gradients for warmth)
- Thin border rules replacing rounded cards
- `§` section markers replacing arrow glyphs
- Double horizontal rules at major section boundaries
- Portrait "caption" styling below featured character

---

## 3. Changes from v6 → v7

| Aspect | v6 (Anime Gacha) | v7 (Vintage Editorial) |
|--------|-------------------|----------------------|
| Background | Dark navy (#0a0e1a) with cyan glow | Aged paper (#E8DCC3) |
| Typography | Sans-serif, game UI | Serif (Georgia), editorial |
| Borders | Glowing rarity borders (SSR=gold, SR=purple, R=blue) | Thin ink rules, accent top-border by rarity |
| Cards | Rounded, dark panels with glow | Flat, paper-toned with thin rules |
| Particles | Floating cyan particles | None (clean editorial) |
| Layout | Game UI grid | Newspaper columns with rules |
| Colored badges | Pill-shaped status badges | Small bordered text labels |
| Header | Compact game bar | Full masthead with double rule |
| Events | Chronology with colored severity pills | Editorial log with bordered severity labels |
| Character frames | Circular with rarity glow | Circular with thin ink border |

---

## 4. Artwork Reused

All 8 character portraits reused from v6 without modification:

| Character | File | Usage |
|-----------|------|-------|
| Rimuru | `slime-art-v6/final/rimuru.png` | Featured story + roster |
| Ciel | `slime-art-v6/final/ciel.png` | Intelligence core + roster |
| Shion | `slime-art-v6/final/shion.png` | Roster |
| Souei | `slime-art-v6/final/souei.png` | Roster |
| Diablo | `slime-art-v6/final/diablo.png` | Roster |
| Gobta | `slime-art-v6/final/gobta.png` | Roster |
| Benimaru | `slime-art-v6/final/benimaru.png` | Roster |
| Ranga | `slime-art-v6/final/ranga.png` | Roster |

---

## 5. Names Preserved

All existing names preserved exactly:
- Application: "Slime OS" / "Mission Control Edition"
- Characters: Rimuru, Ciel, Shion, Souei, Diablo, Gobta, Benimaru, Ranga
- Navigation: Command, Intelligence, Units, Inference, Device, Log
- Sections: Unit Collection, Inference, Memory, Device Link, Mission Log
- Statuses: ONLINE, BUSY, IDLE, Active, Ready, Connected
- Technical: Qwen3.6-35B-A3B, Ollama, Pixel 7a, ADB

---

## 6. Interactions Preserved

All v6 interactions verified working in v7 via automated browser testing:

| Interaction | Result |
|-------------|--------|
| Character selection (click card) | ✓ Shion click → 1 selected, 2 events visible |
| Deselect (click same card) | ✓ 0 selected, all 12 events visible |
| Filter buttons | ✓ Active state toggles correctly |
| Combined filter (card + button) | ✓ Ciel selected + Rimuru filter → 0 events (no Ciel+Rimuru overlap) |
| Escape key reset | ✓ All selections/filters cleared |
| Navigation click | ✓ Active nav item changes |
| Responsive (1440/1280/1024) | ✓ All three widths screenshot-verified |

---

## 7. Responsive Layout

| Width | Body Width | Layout Changes |
|-------|-----------|----------------|
| 1440px | 1440px | Full layout, 280×340px featured portrait |
| 1280px | 1280px | Reduced portrait (240×290px), narrower nav (140px), narrower Ciel panel (200px) |
| 1024px | 1024px | Further reduced (200×240px), narrower nav (120px), narrower Ciel (180px), smaller cards |

---

## 8. Reduced Motion

`@media (prefers-reduced-motion: reduce)` disables all transitions. No continuous animations exist in v7 (the rotating Ciel rings from v6 were removed — they don't fit the editorial style).

---

## 9. Sample Data Declaration

All operational data remains sample data, clearly marked:
- "SAMPLE DATA · v7" badge in bottom-right
- Worker statuses, model info, memory usage, device info, all 12 events, PWR values — all sample

---

## 10. What Was NOT Changed

- No production SwiftUI files modified
- No artwork regenerated
- No new external dependencies
- No paid image-generation APIs used
- All changes confined to `proposals/` directory

---

## 11. Files Created

| File | Size | Purpose |
|------|------|---------|
| `proposals/slime-mission-control-preview-v7.html` | 1.66 MB | Interactive HTML prototype |
| `proposals/slime-mission-control-preview-v7-1440.png` | 442 KB | Screenshot (1440px) |
| `proposals/slime-mission-control-preview-v7-1280.png` | 458 KB | Screenshot (1280px) |
| `proposals/slime-mission-control-preview-v7-1024.png` | 458 KB | Screenshot (1024px) |
| `proposals/slime-mission-control-design-review-v7.md` | ~5 KB | This document |

---

## 12. Open Items

1. **Approve vintage newspaper visual direction for native SwiftUI implementation?**
2. **Should the featured character area have a larger, more prominent portrait** (like a newspaper's front-page photo)?
3. **Ciel's intelligence core:** The rotating rings from v6 were removed. Should a static decorative element (like a printer's ornament or geometric border) replace them?
4. **Roster presentation:** The cards are quite compact. Would you prefer larger cards with more editorial spacing?
5. **Paper texture:** Currently using CSS gradients. Would you prefer a subtle noise/grain texture image?
