# The Slime Herald — Design Review v8 (1925 Newspaper Editorial)

**Date:** 2026-10-13
**Author:** Ciel
**Status:** COMPLETE — awaiting rnz approval
**Preview:** `slime-mission-control-preview-v8.html` (1.67 MB, fully self-contained)
**Source:** `slime-mission-control-preview-v6.html` (anime gacha direction — superseded)
**Screenshots:** `slime-mission-control-preview-v8-1440.png`, `-1280`, `-1024`

---

## 1. Direction

v8 is a complete redesign inspired by a 1925 vintage newspaper front page ("The Old Herald", Sunday Morning, August 20, 1925). The aesthetic is early-20th-century American broadsheet journalism — blackletter masthead, eagle crest, dateline strip, double-rule borders, sepia ink on aged paper, editorial column layout.

This replaces the anime gacha direction (v6/v7) entirely. The application remains a functional mission control dashboard, but presented as a newspaper front page.

---

## 2. Visual System

### Color Palette
| Token | Value | Usage |
|-------|-------|-------|
| `--paper` | `#E9DCC3` | Main background |
| `--paper-light` | `#F2EAD6` | Panel surfaces |
| `--paper-dark` | `#D4C4A4` | Depth accents |
| `--ink` | `#2E2118` | Primary text, rules |
| `--ink2` | `#5C4A35` | Secondary text |
| `--ink3` | `#8A7458` | Tertiary/metadata |
| `--rule` | `#3A2A1B` | Borders (3px double) |
| `--accent` | `#8C3B2E` | Red accent (selected, headings) |

### Typography
- **Masthead:** Pirata One (blackletter/Old English) — "The Slime Herald"
- **Display:** Playfair Display (serif, 900 weight) — character names, Ciel header
- **Labels:** Oswald (condensed sans) — dateline, section titles, metadata
- **Body:** Lora (serif) — event messages, stats values

### Layout Structure
- **Masthead:** Blackletter title + eagle crest SVG + "Mission Control Edition" tagline
- **Dateline bar:** Est. MCMXXV | Sunday Morning | PixelDesktop Command Center | Issue XXXVII | Price
- **Main:** 3-column (nav / featured story / Ciel intelligence)
- **Bottom:** Roster → System Panels → Mission Log, separated by double rules

### Decorative Elements
- Eagle crest SVG (heraldic eagle with shield, stars, stripes, sunburst)
- Sunburst engraving motif behind featured portrait
- `3px double` borders on all cards, panels, portrait frame
- `✦` dingbat section markers
- Multi-layer SVG noise texture for paper grain
- Cross-hatching pattern on eagle wings

---

## 3. Changes from v6 → v8

| Aspect | v6 (Anime Gacha) | v8 (1925 Newspaper) |
|--------|-------------------|----------------------|
| Background | Dark navy with cyan glow | Aged paper (#E9DCC3) |
| Typography | Sans-serif game UI | Blackletter + serif + condensed sans |
| Borders | Glowing rarity borders | 3px double ink rules |
| Cards | Rounded, dark panels | Flat, paper-toned with double rules |
| Particles | Floating cyan particles | None |
| Masthead | Compact game bar | Full newspaper masthead + eagle |
| Events | Chronology with pills | Editorial log with bordered labels |
| Layout | Game UI grid | Newspaper columns |
| Fonts | System fonts | Google Fonts (Pirata One, Playfair, Oswald, Lora) |

---

## 4. Artwork Reused

All 8 character portraits reused from v6 without modification:
- Rimuru (featured + roster)
- Ciel (intelligence core + roster)
- Shion, Souei, Diablo, Gobta, Benimaru, Ranga (roster)

---

## 5. Names Preserved

All existing names preserved exactly:
- Application: "The Slime Herald" / "Mission Control Edition"
- Characters: Rimuru, Ciel, Shion, Souei, Diablo, Gobta, Benimaru, Ranga
- Navigation: Command, Intelligence, Units, Inference, Device, Log
- Sections: Unit Collection, Inference, Memory, Device Link, Mission Log
- Statuses: ONLINE, BUSY, IDLE, Active, Ready, Connected
- Technical: Qwen3.6-35B-A3B, Ollama, Pixel 7a, ADB

---

## 6. Interactions Tested (All Pass)

| Interaction | Result |
|-------------|--------|
| Character selection (click card) | ✓ Shion click → 1 selected, 2 events visible |
| Deselect (click same card) | ✓ 0 selected, all 12 events visible |
| Filter buttons | ✓ Active state toggles correctly |
| Combined filter (card + button) | ✓ Ciel selected + Rimuru filter → 0 events (no overlap) |
| Escape key reset | ✓ All selections/filters cleared |
| Navigation click | ✓ Active nav item changes |
| Fonts loaded | ✓ Pirata One (masthead), Lora (body) |
| Responsive 1440/1280/1024 | ✓ All three widths screenshot-verified |

---

## 7. Responsive Layout

| Width | Body Width | Layout Changes |
|-------|-----------|----------------|
| 1440px | 1440px | Full layout, 240×290px featured portrait |
| 1280px | 1280px | Reduced portrait (200×240px), narrower nav (120px), narrower Ciel (180px) |
| 1024px | 1024px | Further reduced (160×200px), narrower nav (100px), narrower Ciel (160px), smaller cards |

---

## 8. Visual Analysis Results

**Vision analysis rating: 6-7/10** — "Strong concept and correct ingredients, but execution falls short of premium authentic."

### Strengths
- Blackletter masthead is period-correct and striking
- Color palette is cohesive (sepia, cream, ink, brick red)
- Typography hierarchy is clear and readable
- Double-rule borders on portrait and stats card work well
- Sunburst motif behind featured portrait adds depth

### Known Limitations
- **Eagle crest SVG** — At small sizes (56×48px), SVG line art cannot achieve the detail of a true engraving. The current version has layered feathers, breast shield, stars, stripes, and sunburst, but reads as "stylized bird" rather than "heraldic eagle" at this scale.
- **Paper texture** — SVG noise layers provide subtle grain (6-8% opacity), but cannot match the organic fiber variation of real newsprint.
- **Headline layout** — Centered hero-style headline is a modern convention. Period newspapers used multi-column justified text. This is a deliberate compromise for dashboard readability.
- **Page density** — Real 1920s front pages were densely packed with 6-8 columns. The current layout has intentional whitespace for dashboard legibility.

### Trade-offs Made
- Dashboard functionality prioritized over historical accuracy
- SVG art used instead of bitmap engravings (file size and scalability)
- CSS noise instead of paper texture images (self-contained HTML)
- Modern interaction patterns (hover, click, filters) preserved from v6

---

## 9. Sample Data Declaration

All operational data remains sample data, clearly marked:
- "SAMPLE DATA · Vol. VIII" badge in bottom-right
- Worker statuses, model info, memory usage, device info, all 12 events, PWR values — all sample

---

## 10. What Was NOT Changed

- No production SwiftUI files modified
- No artwork regenerated
- No new external dependencies (Google Fonts is the only external resource)
- All changes confined to `proposals/` directory

---

## 11. Files Created

| File | Size | Purpose |
|------|------|---------|
| `proposals/slime-mission-control-preview-v8.html` | 1.67 MB | Interactive HTML prototype |
| `proposals/slime-mission-control-preview-v8-1440.png` | 687 KB | Screenshot (1440px) |
| `proposals/slime-mission-control-preview-v8-1280.png` | 702 KB | Screenshot (1280px) |
| `proposals/slime-mission-control-preview-v8-1024.png` | 735 KB | Screenshot (1024px) |
| `proposals/slime-mission-control-design-review-v8.md` | ~6 KB | This document |

---

## 12. Open Items for rnz

1. **Approve 1925 newspaper visual direction for native SwiftUI implementation?**
2. **Eagle crest:** Current SVG is stylized. Should I attempt a more detailed engraving-style version, or is the current abstraction acceptable?
3. **Paper texture:** Current SVG noise is subtle. Should I add a more prominent grain texture image?
4. **Page density:** Should I add more "newspaper-like" content (column text, ad blocks, weather box) to fill whitespace, or keep the clean dashboard layout?
5. **Google Fonts dependency:** Currently requires internet for fonts. Should I bundle fonts locally or accept system font fallbacks for offline use?
6. **Scope:** New "Dashboard" segment in RootView, or replace one of the existing segments?

---

## 13. Technical Notes

- **CSS `border: 3px double`** used for double-rule effect on cards, panels, portrait frame, dateline, nav divider, bottom section
- **SVG noise texture** via `feTurbulence` with two layers (fine grain 0.7 frequency + broad mottling 0.3 frequency) at 6-8% opacity
- **Eagle SVG** uses `pattern` with cross-hatching for wing/body fill, layered feather paths, star field, stripe details
- **Google Fonts** loaded via CDN link — requires internet connection for first load
- **No JavaScript frameworks** — vanilla JS for all interactions
- **Fully self-contained** except for Google Fonts CDN
