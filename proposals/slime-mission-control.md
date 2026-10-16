# Proposal: Slime Mission Control — PixelDesktop Agent Dashboard

**Date:** 2026-10-13
**Author:** Ciel (proposed to rnz)
**Status:** DRAFT — awaiting approval
**Inspiration:** Jack Roberts' "Mission Control OS" dashboard (Hermes web workspace, `localhost:8081/agents/hermes`)  
**Thematic twist:** Replace Greek god pantheon with *That Time I Got Reincarnated as a Slime* characters

---

## 1. What We're Building

A native SwiftUI dashboard inside PixelDesktop that surfaces every agent, worker, connection, and activity in one operator-facing interface. Adapts the layout patterns from the reference dashboard (left sidebar, stat cards, integration pills, hero banner) but re-skinned with Slime theming and wired into PixelDesktop's actual data sources.

---

## 2. Reference Dashboard Analysis (What We're Adapting)

From the screenshot of `localhost:8081/agents/hermes`:

| Zone | What It Does | Our Adaptation |
|------|-------------|----------------|
| **Header bar** | Logo, breadcrumb, status badge, notification bell | App title, agent status, notification indicator |
| **Left sidebar** | Nav: Home, Skills, Memory, Activity; Agent list below | Nav: Dashboard, Agents, Sessions, Skills, Memory, Activity; Worker/agent list |
| **Hero banner** | Blue-tinted classical artwork (School of Athens) | Slime-themed banner (Tempest/Jura forest scene) |
| **Integration pills** | Horizontal row of connected services with status dots | Connected services: Zeno, Ollama, OpenCode, ADB, Discord bridge |
| **Stat cards (×4)** | Agent version, active model, memory usage, activity metric | Worker status, active model, memory/disk, inference throughput |
| **Bottom panel** | Chat/conversation area with "New Chat" button | Live event stream / worker output console |

---

## 3. Character-to-Agent Mapping

Replace the Greek god pantheon with Slime characters. Each character maps to a real PixelDesktop subsystem:

| Slime Character | Role in Dashboard | PixelDesktop Subsystem | Rationale |
|-----------------|-------------------|------------------------|-----------|
| **Rimuru Tempest** | Main orchestrator / CEO | `AppState` + `RootView` | The slime who coordinates everything; equivalent to Hermes/Ciel |
| **Ciel** | Memory & knowledge manager | `ZenoObservabilityStore` + `ZenoEventStoreAdapter` | The evolved Great Sage; already our memory/observability layer |
| **Shion** | Worker / compute engine | `DTCA1Worker` + `LlmJob` | The powerhouse who gets things done; heavy lifting |
| **Souei** | Reconnaissance & device discovery | `DeviceDiscovery` + `DeviceEnricher` | The spy; scouts and reports on connected devices |
| **Diablo** | Inference / model runtime | `InferenceRuntime` + `ModelProvisioning` | The elegant but powerful one; handles AI model execution |
| **Gobta** | File & transport operations | `ADBTransport` + `WorkerTransferContract` | The hardworking but reliable one; moves data around |
| **Benimaru** | Security & verification | `ResultVerifier` + `CredentialProvider` | The strict enforcer; checks everything before it ships |
| **Ranga** | Background tasks / cron | `WorkerLifecycle` + scheduled jobs | The ever-present support; runs continuously in the background |

---

## 4. Panel-by-Panel Design

### 4.1 Header Bar

```
┌──────────────────────────────────────────────────────────────────┐
│  🟣 SLIME OS          Operator / local          🔔 │
│                                              🟢 ONLINE         │
└──────────────────────────────────────────────────────────────────┘
```

**Elements:**
- Left: Slime logo (purple circle icon) + "SLIME OS" title + breadcrumb
- Right: Agent status badge (green "ONLINE" / yellow "BUSY" / red "OFFLINE"), notification bell

**Data source:** `AppState.workerStatus`, `ServiceStatus` aggregate

---

### 4.2 Left Sidebar — Navigation

```
┌──────────────┐
│  DASHBOARD   │
│  AGENTS      │
│  SESSIONS    │
│  SKILLS      │
│  MEMORY      │
│  ACTIVITY    │
│              │
│  WORKERS     │
│  🟣 Rimuru   │
│  🔵 Ciel     │
│  🟠 Shion    │
│  🟢 Souei    │
│  ⚫ Diablo   │
│  🟤 Gobta    │
│  🔴 Benimaru │
│  🟡 Ranga    │
└──────────────┘
```

**Elements:**
- Top: Navigation items (Dashboard, Agents, Sessions, Skills, Memory, Activity)
- Section label: "WORKERS"
- Bottom: Color-coded worker/agent list with status indicators
- Active item highlighted (light background)

**Data source:** `AppState`, `WorkerLifecycle`, `ServiceStatus`

---

### 4.3 Hero Banner

```
┌──────────────────────────────────────────────────────────────────┐
│          [Slime-themed artwork: Jura Forest / Tempest]          │
│                                                                  │
│              "Every agent. Every connection.                     │
│                   One command center."                           │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

**Elements:**
- Full-width banner with Slime-themed artwork (purple/blue gradient, Jura forest motif)
- Centered tagline
- Optional: subtle animated slime blob

**Data source:** Static asset (no live data needed)

---

### 4.4 Integration Pills Row

```
┌──────────────────────────────────────────────────────────────────�
│  Rimuru                              🟢 Zeno                   │
│  Global                              🟢 Ollama                 │
│                                      🟢 OpenCode               │
│                                      🟢 ADB                    │
│                                      🟡 Discord Bridge         │
└──────────────────────────────────────────────────────────────────┘
```

**Elements:**
- Left: Two tabs — "Rimuru" (this agent) and "Global" (all agents)
- Right: Horizontal scrollable row of integration pills
- Each pill: service name + colored status dot (green/yellow/red)
- Clickable to show connection details

**Data source:** `ServiceStatus` (Zeno, Ollama, OpenCode, ADB, Discord bridge)

---

### 4.5 Stat Cards Row (4 cards)

#### Card 1 — WORKER STATUS (Rimuru)

```
┌────────────────────────┐
│  WORKER                │
│  v2.4.1                │
│  🟢 ONLINE             │
│  2026.10.13            │
└────────────────────────┘
```

**Data source:** `AppState.workerVersion`, `AppState.workerStatus`

#### Card 2 — ACTIVE MODEL (Diablo)

```
┌────────────────────────┐
│  ACTIVE MODEL          │
│  Qwen3.6-35B-A3B       │
│  via Ollama            │
│  ────────────────────  │
│  QWEN  LONGCAT  CLAUDE │
│  (segmented model      │
│   selector)            │
└────────────────────────┘
```

**Data source:** `InferenceRuntime.currentModel`, `ModelProvisioning.availableModels`

#### Card 3 — MEMORY & OBSERVABILITY (Ciel)

```
┌────────────────────────┐
│  MEMORY                │
│  3.6k / 4.4k CHARS     │
│  ████████████░░░  77%  │
│  20 SESSIONS           │
└────────────────────────┘
```

**Data source:** `ZenoObservabilityStore.sessionCount`, `ZenoEventStoreAdapter.eventCount`

#### Card 4 — ACTIVITY METRIC (Shion)

```
┌────────────────────────┐
│  42                    │
│  THIS WEEK             │
│  ▁▃▅▂▇▃▁  (bar chart)  │
│  128 TOTAL · 12H COMP  │
└────────────────────────┘
```

**Data source:** `ZenoEventStoreAdapter.weeklyActivity`, `WorkerComputeProof.totalJobs`

---

### 4.6 Bottom Panel — Live Event Stream

```
┌──────────────────────────────────────────────────────────────────┐
│  ≫ LIVE EVENT STREAM                              [NEW SESSION] │
│  ─────────────────────────────────────────────────────────────── │
│  11:23:01  🟢 Rimuru     Worker Shion started LLM job #42       │
│  11:22:45  🔵 Ciel       Memory updated: 3 new sessions indexed  │
│  11:22:30  🟠 Shion      Inference completed: 1,247 tokens      │
│  11:22:15  🟢 Souei      Device Pixel 7a connected (ADB)        │
│  11:21:58  ⚫ Diablo     Model Qwen3.6-35B loaded (Ollama)     │
│  11:21:30  🟤 Gobta      File transfer: 2.3 MB → device         │
│  11:20:45  🔴 Benimaru   Verification passed: run #38            │
│  11:20:00  🟡 Ranga      Cron: daily snapshot backed up          │
│  ...                                                             │
└──────────────────────────────────────────────────────────────────┘
```

**Elements:**
- Collapsible header bar (chevron toggle)
- "NEW SESSION" button (starts fresh worker session)
- Scrollable event list with timestamp, character avatar (colored dot), worker name, event description
- Color-coded by severity/type
- Optional: filter by worker, filter by event type

**Data source:** `ZenoEventStoreAdapter` (real-time), `AppLogger`, `WorkerStreamRunner` output

---

## 5. Theming & Visual Design

### Color Palette

| Element | Color | Hex |
|---------|-------|-----|
| Primary (Rimuru) | Tempest Purple | `#7B68EE` |
| Secondary (Ciel) | Great Sage Blue | `#4A90D9` |
| Accent (Shion) | Oni Orange | `#FF6B35` |
| Success (Souei) | Forest Green | `#4CAF50` |
| Danger (Benimaru) | Crimson | `#DC143C` |
| Warning (Ranga) | Goldenrod | `#DAA520` |
| Neutral (Gobta) | Earth Brown | `#8B7355` |
| Dark (Diablo) | Midnight | `#2C3E50` |

### Typography

- SF Pro (system font) for all UI elements
- Monospace for event stream and stat values
- Hero banner: Large title weight, white with subtle shadow

### Layout

- **macOS-native:** Dark mode support, sidebar with translucent material
- **Responsive:** Sidebar collapses to icon-only on narrow windows
- **Animations:** Subtle pulse on status indicators, smooth transitions between panels

---

## 6. Architecture & Data Flow

```
┌─────────────────────────────────────────────────┐
│                  RootView                        │
│  ┌─────────────────────────────────────────────┐ │
│  │  Segmented Picker: [Dashboard | Device |    │ │
│  │  Observability]                            │ │
│  └─────────────────────────────────────────────┘ │
│  ┌──────────┐  ┌──────────────────────────────┐  │
│  │ Sidebar  │  │  Main Content                │  │
│  │          │  │  ┌────────────────────────┐  │  │
│  │ Nav      │  │  │ Header Bar             │  │  │
│  │ Workers  │  │  └────────────────────────┘  │  │
│  │          │  │  ┌────────────────────────┐  │  │
│  │          │  │  │ Hero Banner            │  │  │
│  │          │  │  └────────────────────────┘  │  │
│  │          │  │  ┌────────────────────────┐  │  │
│  │          │  │  │ Integration Pills      │  │  │
│  │          │  │  └────────────────────────┘  │  │
│  │          │  │  ┌────┐┌────┐┌────┐┌────┐   │  │
│  │          │  │  │ S1 ││ S2 ││ S3 ││ S4 │   │  │
│  │          │  │  └────┘└────┘└────┘└────┘   │  │
│  │          │  │  ┌────────────────────────┐  │  │
│  │          │  │  │ Live Event Stream      │  │  │
│  │          │  │  └────────────────────────┘  │  │
│  └──────────┘  └──────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

### New Files to Create

```
PixelDesktop/App/Dashboard/
├── DashboardView.swift           # Main dashboard container (sidebar + content)
├── DashboardSidebarView.swift    # Left nav + worker list
├── DashboardHeaderView.swift     # Top bar with status
├── DashboardHeroView.swift       # Banner with tagline
├── DashboardIntegrationsView.swift  # Integration pills row
├── DashboardStatCardsView.swift  # 4-card stat row
├── DashboardEventStreamView.swift   # Live event stream panel
├── DashboardModels.swift         # View models for dashboard data
├── DashboardTheming.swift        # Colors, fonts, reusable components
└── DashboardDataSources.swift    # Protocols for data adapters
```

### Data Source Adapters

Each dashboard panel reads from a protocol, not directly from the store:

```swift
protocol DashboardDataSource {
    var workerStatus: WorkerStatus { get }
    var activeModel: ModelInfo { get }
    var memoryUsage: MemoryStats { get }
    var weeklyActivity: ActivityStats { get }
    var connections: [ServiceConnection] { get }
    var events: [DashboardEvent] { get }
}
```

This keeps the UI testable with mock data and decouples it from Zeno/Ollama internals.

---

## 7. Implementation Phases

### Phase 1: Skeleton & Theming (M1)
- Create `Dashboard/` directory with all files
- Implement `DashboardTheming.swift` (colors, reusable components)
- Wire `DashboardView` into `RootView` as a third segment
- Empty panels with correct layout, no live data
- **Gate:** Build passes, all panels render with placeholder content

### Phase 2: Data Wiring (M2)
- Implement `DashboardDataSources.swift` with real adapters
- Wire stat cards to `ZenoObservabilityStore`, `InferenceRuntime`, `ServiceStatus`
- Wire integration pills to `ServiceStatus`
- Wire sidebar worker list to `AppState`
- **Gate:** All panels show real data from live sources

### Phase 3: Event Stream (M3)
- Implement `DashboardEventStreamView` with live polling
- Wire to `ZenoEventStoreAdapter` for real-time events
- Add filtering and search
- **Gate:** Events appear in real-time as workers operate

### Phase 4: Polish & Theming (M4)
- Add Slime-themed artwork (hero banner, sidebar icons)
- Animations and transitions
- Dark mode refinement
- PWA-style responsiveness (if applicable)
- **Gate:** Visual review passed by rnz

---

## 8. What This Does NOT Do

- **Not a replacement** for the existing Device or Observability views — it's a third segment
- **Not a chat interface** — no conversational AI in the dashboard (that's what Hermes/Multica is for)
- **Not a config editor** — no settings changes from the dashboard (CLI and config files handle that)
- **Read-only** — the dashboard is an operator view, not a control surface (except "New Session" button)

---

## 9. Artwork Pipeline (Verified)

Before writing any art into the proposal, every plausible image-generation route on this machine was
tested. Results as of 2026-10-13:

| Route | Status | Evidence |
|-------|--------|----------|
| Hermes `image_gen` toolset (FAL) | **Unavailable** | `FAL_KEY` unset in env and `~/.hermes/.env`; `fal_key_configured()` → False |
| Nous managed gateway (`fal-queue`) | **Unavailable** | `resolve_managed_tool_gateway('fal-queue')` → `None`; account not entitled |
| OpenRouter image models | **Blocked** | HTTP 402 — "requires at least $1.00 in balance"; account balance `$0` / `$0` used |
| Local diffusion (mflux / ComfyUI / Draw Things) | **Not installed** | No binaries or app bundles found |
| Ollama | **Not installed** | `which ollama` → empty |
| **Pollinations (FLUX)** | **Working** | HTTP 200, real diffusion output; free, no API key |

**Conclusion:** the only functioning image-generation path is Pollinations, a free public FLUX
endpoint with no API key. It rate-limits burst requests (HTTP 402 under load), so generation is
paced with backoff. Output carries a `pollinations.ai` watermark in the bottom-right corner; since
the portraits are centred bust shots, a 1.22× centre-zoom crop removes the watermark while keeping
the character framed.

**Caveat for the real build:** Pollinations is a public third-party endpoint with no SLA. It is
adequate for design mockups, but the shipped app should not depend on it. Either bundle the approved
artwork as static assets in the app, or wire the dashboard to a proper image backend once one is
provisioned.

---

## 10. Open Questions for rnz

1. **Artwork:** Generated FLUX portraits are used in the preview. Do you want these kept, or do you
   have specific Slime artwork to use instead?
2. **Scope:** Should the dashboard also show Android device stats (CPU, memory, battery) or is that still the Device view's job?
3. **Interactions:** Should clicking a worker in the sidebar filter the event stream to that worker only?
4. **Notifications:** Should the bell icon show actual alerts (e.g., device disconnected, job failed)?
5. **Priority:** Should I build this as a new "Dashboard" segment, or replace one of the existing segments?

---

**Awaiting approval to proceed to implementation.**
