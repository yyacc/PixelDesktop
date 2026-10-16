# PixelDesktop Remote Storage — Proposal

**Date:** 2026-10-16  
**Author:** Ciel  
**Status:** DRAFT — Pending Approval

---

## 1. Vision

Turn the Pixel 7a into rnz's remote storage device, accessible through the PixelDesktop Mac app. The phone becomes a wireless drive that rnz can browse, upload to, download from, and manage — all from the desktop interface.

**Core capabilities:**
- Persistent wireless connection (WiFi) — access Pixel 7a files from anywhere on the internet
- Wired mode priority — when USB is plugged in, prefer wired connection
- File operations: list, upload, download, delete, create folders, rename
- Ciel can retrieve all information from Pixel 7a for knowledge/workflow purposes
- Remove Zeno observability (no longer needed)

---

## 2. Current State Assessment

| Component | Status | Notes |
|-----------|--------|-------|
| Device discovery | ✅ Working | WiFi/Bonjour + USB detection |
| Transport seam | ✅ Abstracted | TransportState protocol exists |
| CLI boundary | ✅ Solid | 506 tests passing |
| Zeno observability | ⚠️ Remove | User deleted Zeno, functionality obsolete |
| File access service | ❌ Missing | Core new feature |
| Remote storage UI | ❌ Missing | Core new feature |
| Wireless transport | ⚠️ Partial | Discovery works, persistent connection does not |
| Wired priority | ❌ Missing | No transport selection logic |

---

## 3. Technical Approach

### 3.1 Connection Architecture

**Wireless Mode (Primary):**
- Use ADB over WiFi (Android Wireless Debugging)
- Pixel 7a exposes IP:port when Wireless Debugging is enabled
- Mac runs `adb connect <ip>:<port>` to establish connection
- ADB provides: `adb push`, `adb pull`, `adb shell` for full file access
- Auto-reconnect on network change (NWPathMonitor)
- Connection state persisted in UserDefaults

**Wired Mode (Priority):**
- When USB is connected, ADB automatically detects device
- Transport selection: USB > WiFi (wired always preferred)
- USB connection = lower latency, no network dependency, faster transfers

**Transport Priority Logic:**
```
if USB connected → use USB (fastest, most reliable)
else if WiFi paired → use wireless ADB
else → offline / disconnected state
```

### 3.2 File Operations via ADB

ADB provides everything needed for file management:

| Operation | ADB Command |
|-----------|-------------|
| List files | `adb shell ls -la <path>` |
| Upload file | `adb push <local> <remote>` |
| Download file | `adb pull <remote> <local>` |
| Delete file | `adb shell rm <path>` |
| Create folder | `adb shell mkdir <path>` |
| Rename/move | `adb shell mv <src> <dst>` |
| Disk space | `adb shell df -h` |
| File info | `adb shell stat <path>` |

### 3.3 App Architecture Changes

```
PixelDesktop/
├── Device/                    # Existing — discovery + connection
│   ├── DeviceManager.swift    # Add: transport selection logic
│   ├── DeviceDiscovery.swift  # Keep as-is
│   └── TransportState.swift   # Extend: wired/wireless priority
├── Storage/                   # NEW — file operations layer
│   ├── StorageService.swift   # ADB file operations wrapper
│   ├── StorageItem.swift      # File/folder model
│   ├── StorageTransfer.swift  # Upload/download progress tracking
│   └── StorageErrors.swift    # Typed errors
├── StorageUI/                 # NEW — SwiftUI views
│   ├── StorageBrowserView.swift    # File browser
│   ├── StorageTransferView.swift   # Transfer progress
│   └── StorageToolbarView.swift    # Upload/delete/new folder
├── Observability/             # REMOVE — Zeno no longer needed
│   └── (delete entire directory)
└── App/
    ├── ContentView.swift      # Add Storage tab
    └── PixelDesktopApp.swift  # Update navigation
```

### 3.4 Security Considerations

- ADB pairing is one-time, device-specific
- Wireless Debugging requires explicit user enable on device
- No cloud intermediary — direct device-to-Mac connection
- ADB over USB is inherently local (no network exposure)
- ADB over WiFi is on local network only (or VPN if configured)

---

## 4. Implementation Phases

### Phase 1: Connection Foundation
**Goal:** Persistent wireless + wired priority connection

- [ ] Extend TransportState for wired/wireless modes
- [ ] Implement transport selection logic (USB > WiFi)
- [ ] Add NWPathMonitor for network change detection
- [ ] Auto-reconnect on connection loss
- [ ] Connection state persistence (UserDefaults)
- [ ] Update DeviceManager to handle dual transport

**Delegates well to:** Low-level agent (clear ADB commands, deterministic logic)

### Phase 2: Storage Service Layer
**Goal:** File operations via ADB

- [ ] Create StorageService with ADB wrapper
- [ ] Implement list, upload, download, delete, mkdir, rename
- [ ] Transfer progress tracking (ADB doesn't provide native progress)
- [ ] Error handling (device offline, permission denied, disk full)
- [ ] Disk space reporting
- [ ] Unit tests for all operations

**Delegates well to:** Mid-level agent (ADB commands are deterministic, but error handling needs care)

### Phase 3: Storage UI
**Goal:** File browser in PixelDesktop app

- [ ] StorageBrowserView — file/folder listing
- [ ] Navigation (tap to enter folders, back button)
- [ ] Upload button (file picker → adb push)
- [ ] Download button (adb pull → save panel)
- [ ] Delete with confirmation
- [ ] New folder creation
- [ ] Rename
- [ ] Transfer progress overlay
- [ ] Connection status indicator
- [ ] Empty state / offline state

**Delegates well to:** Mid-level agent (standard SwiftUI patterns, but needs design sense)

### Phase 4: Zeno Removal + Cleanup
**Goal:** Remove obsolete Zeno observability

- [ ] Delete PixelDesktop/Observability/ directory
- [ ] Remove Zeno references from ContentView
- [ ] Remove Zeno event store adapter
- [ ] Update tests (remove Zeno-related tests)
- [ ] Update CLI commands if they reference observability
- [ ] Verify full test suite passes

**Delegates well to:** Low-level agent (mechanical deletion + test updates)

### Phase 5: Integration + Testing
**Goal:** End-to-end verification

- [ ] Full test suite passes (existing + new storage tests)
- [ ] Manual test: wireless connection persists across app restarts
- [ ] Manual test: USB priority (plug in USB → switches to wired)
- [ ] Manual test: file upload/download/delete/create
- [ ] Manual test: Ciel can retrieve files from Pixel 7a
- [ ] Performance check: large file transfers work
- [ ] Edge cases: connection loss mid-transfer, disk full, permissions

**Delegates well to:** Mid-level agent (integration testing, edge cases)

---

## 5. Agent Capability Mapping

| Phase | Complexity | Recommended Agent | Reason |
|-------|-----------|-------------------|--------|
| Phase 1 | Low-Mid | Qwen agent | Deterministic ADB logic, clear spec |
| Phase 2 | Mid | Qwen agent | ADB commands + error handling |
| Phase 3 | Mid | Qwen agent | Standard SwiftUI, but needs polish |
| Phase 4 | Low | Any agent | Mechanical deletion |
| Phase 5 | Mid | Ciel (me) | Integration testing requires full context |

---

## 6. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| ADB connection drops during transfer | Failed upload/download | Retry with exponential backoff, resume support |
| Wireless ADB not enabled | Can't connect wirelessly | Clear setup instructions in UI, fallback to USB |
| Large file slow over WiFi | Poor user experience | Show transfer progress, warn for files >100MB |
| Permission denied on Android | Can't access certain paths | Use app-specific storage or /sdcard with proper permissions |
| ADB port changes on phone restart | Connection lost | Auto-recovery via Bonjour re-discovery |
| Multiple devices | Wrong device targeted | Device selection UI (already exists in DeviceManager) |

---

## 7. Decisions (Confirmed by rnz)

1. **Storage location:** `/sdcard/PixelDesktop/` — dedicated folder on Pixel 7a main storage ("renting a storage space inside the pixel")
2. **Use case:** Mixed — documents + media (photos, videos, files up to reasonable size)
3. **Access scope:** Both local network AND remote access (VPN/Tailscale for outside home network)
4. **Authentication:** ADB pairing is sufficient (one-time, device-specific)
5. **Encryption:** Not required for v1 — ADB over local network is acceptable; can add later

---

## 8. Success Criteria

- [ ] rnz can open PixelDesktop and browse Pixel 7a files wirelessly
- [ ] Plug in USB → connection switches to wired automatically
- [ ] Unplug USB → connection falls back to wireless
- [ ] Upload a file from Mac to Pixel 7a
- [ ] Download a file from Pixel 7a to Mac
- [ ] Delete files on Pixel 7a from the app
- [ ] Create folders on Pixel 7a from the app
- [ ] Ciel can retrieve any file from Pixel 7a for task purposes
- [ ] Zeno observability completely removed
- [ ] Full test suite passes
- [ ] Works across app restarts (connection persists)

---

**Awaiting approval before proceeding to implementation.**
