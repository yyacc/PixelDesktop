PixelDesktop — Architecture Documentation

Table of Contents

1. I. Overview
2. II. System Model
3. III. Technology Stack
4. IV. macOS Application Architecture
5. V. Android Device Architecture
6. VI. Device Communication
7. VII. Device Discovery and Monitoring
8. VIII. Android Discovery and Metadata
9. IX. scrcpy Integration
10. X. Data and Control Flow
11. XI. Reliability and Constraints
12. XII. Verification
13. XIII. Future Compute-Node Architecture
14. XIV. Architectural Decisions
15. XV. Implementation Status

⸻

I. Overview

PixelDesktop is a native macOS application designed to control and coordinate a physical Android device as a local compute node.

The current system connects a MacBook to a physical Google Pixel 7a running Android 16.

The project is deliberately built around a real Android device rather than an emulator.

The current implementation focuses on device discovery, ADB communication, device monitoring, Android application discovery, metadata retrieval, and controlled device interaction.

The longer-term direction is distributed local computing, where the Pixel can perform specialized lightweight workloads while the Mac remains the primary desktop interface and reasoning/orchestration system.

⸻

II. System Model

The system consists of two physical computing environments.

MacBook
   │
   │ PixelDesktop
   │
   │ ADB / mDNS
   ▼
Physical Pixel 7a
   │
   └── Android 16

A. MacBook

The MacBook is the primary:

* Desktop interface
* Keyboard and mouse environment
* PixelDesktop application host
* Planning and orchestration environment

The Mac is also expected to handle heavier models and more complex reasoning in the future distributed architecture.

B. Pixel 7a

The Pixel 7a is a physical Android device used as the Android-side compute node.

It provides its own:

* CPU
* GPU
* RAM
* Storage
* Android runtime

The architecture does not attempt to pool physical RAM between the Mac and Pixel into one shared memory space.

⸻

III. Technology Stack

* Language: Swift
* UI: SwiftUI
* Platform: macOS
* Development: Xcode
* Device communication: Android Debug Bridge (ADB)
* Device discovery: mDNS
* Android device: Google Pixel 7a
* Android version: Android 16
* Device interaction: scrcpy

⸻

IV. macOS Application Architecture

A. AppState

AppState is the primary observable application state layer.

* Runs on @MainActor
* Uses @Observable
* Provides application state to the SwiftUI interface

B. ADBService

ADBService is an actor responsible for ADB operations.

Its purpose is to isolate asynchronous device communication from the main UI execution context.

C. DeviceManager

DeviceManager is an actor responsible for device discovery and monitoring.

Its responsibilities include:

* Discovering devices
* Managing connection state
* Supporting USB/direct-wireless connection paths
* Supporting mDNS discovery
* Monitoring device availability

The current monitoring implementation uses a three-second cancellable interval.

D. SwiftUI Interface

SwiftUI provides the native macOS user interface.

The UI communicates with the state and device-management layers rather than treating Android screen mirroring as the application’s primary interface.

⸻

V. Android Device Architecture

PixelDesktop connects to a real Pixel 7a rather than an emulator.

The Android device is treated as an independent physical computing node.

Current device-side capabilities used by the project include:

* ADB communication
* Android package discovery
* Launcher activity discovery
* Device metadata
* Application metadata retrieval

The Android side is intended to become more useful as a compute worker over time, but that distributed worker architecture is currently planned rather than fully implemented.

⸻

VI. Device Communication

A. Android Debug Bridge

Android Debug Bridge is the primary communication mechanism between PixelDesktop and the Pixel 7a.

ADB provides the mechanism for:

* Connecting to the device
* Inspecting device information
* Discovering Android packages and activities
* Accessing permitted application metadata
* Launching supported device interactions

B. USB

USB is an important local connection path.

The project favors USB when available because it avoids some of the reliability issues encountered with wireless ADB.

C. Direct Wireless ADB

Direct wireless ADB is also supported as a connection path.

During development, wireless ADB experienced connection and disconnection reliability issues.

The architecture therefore does not assume wireless connectivity is always stable.

D. mDNS

mDNS is used as part of device discovery for supported network discovery scenarios.

⸻

VII. Device Discovery and Monitoring

The device-management layer performs device discovery and monitors device availability.

Discovery
   │
   ├── USB
   │
   ├── Direct Wireless
   │
   └── mDNS
          │
          ▼
     DeviceManager
          │
          ▼
       AppState
          │
          ▼
    SwiftUI Interface

The current monitoring implementation uses a three-second cancellable monitoring interval.

⸻

VIII. Android Discovery and Metadata

PixelDesktop can inspect the connected Android environment.

A. Package Discovery

The application can discover Android packages installed on the device.

B. Launcher Activity Discovery

During development, package and activity discovery successfully identified 82 launcher activities on the connected Pixel 7a.

This is a development observation and not a fixed architectural limit.

C. Metadata Retrieval

The project retrieves Android-side metadata through the existing ADB path.

The metadata workflow uses run-as to access permitted application metadata.

The Android-side metadata is represented through metadata.json.

This approach avoids introducing a separate HTTP server solely for metadata transfer.

⸻

IX. scrcpy Integration

scrcpy is integrated as a device interaction mechanism.

It provides a practical way to interact with the physical Android device from the Mac during development.

However, scrcpy is not the intended final endpoint of PixelDesktop.

The project is not being developed as a simple screen-mirroring application.

The longer-term objective is to control and use device capabilities through a higher-level architecture.

⸻

X. Data and Control Flow

A simplified current flow is:

User
 │
 ▼
PixelDesktop SwiftUI UI
 │
 ▼
AppState
 │
 ▼
DeviceManager / ADBService
 │
 ▼
ADB
 │
 ▼
Physical Pixel 7a
 │
 ├── Device information
 ├── Packages / activities
 └── Application metadata

The application therefore treats ADB as a device-control boundary rather than embedding Android execution directly inside the macOS process.

⸻

XI. Reliability and Constraints

A. Local-First Communication

The architecture favors local communication where practical.

USB is preferred when available.

Wireless discovery and communication provide additional flexibility but are not assumed to be perfectly reliable.

B. Sandbox Decision

The development sandbox was removed because Homebrew ADB did not function correctly inside the sandbox environment.

The current project does not depend on restoring that sandbox.

C. Security and Scope Constraints

The project intentionally avoids:

* APK modification
* Code injection
* Anti-cheat bypasses
* Destructive Android actions
* Security-bypass mechanisms

The objective is to use the Android device through supported development and device-control mechanisms.

⸻

XII. Verification

Verification performed during development has included:

* Project builds
* Application launch at working checkpoints
* Device discovery
* ADB communication
* Package discovery
* Launcher activity discovery
* Metadata retrieval
* scrcpy launch
* Five tests passing at a development checkpoint

The documentation does not make an automated test-coverage claim because a verified coverage percentage has not been established.

⸻

XIII. Future Compute-Node Architecture

The long-term direction is to use the Pixel 7a as a specialized local worker.

                  MacBook
        ┌─────────────────────────┐
        │ Interface               │
        │ Architecture            │
        │ Planning                │
        │ Complex reasoning       │
        │ Orchestration           │
        └────────────┬────────────┘
                     │
                Task Routing
                     │
             ┌───────┴───────┐
             ▼               ▼
           Mac            Pixel 7a
      Heavy/complex      Lightweight
         workloads         workloads
                             │
                    ┌────────┼────────┐
                    ▼        ▼        ▼
                  Small    Scripts   Tests
                   AI      /code    /analysis

Potential Pixel workloads include:

* Small quantized local AI models
* Lightweight coding tasks
* Small code edits
* Script execution
* Local code analysis
* Test execution
* Other constrained workloads suitable for the device

The initial target for local coding models is roughly the 1–3B parameter range, while larger or more complex reasoning remains better suited to the Mac.

This is a planned architecture, not a claim that the current application already performs distributed AI task routing.

⸻

XIV. Architectural Decisions

A. Physical Device Instead of Emulator

1. Decision

Use a physical Pixel 7a as the Android-side node.

2. Reason

The project is intended to use the actual resources and Android environment of a real device.

B. Mac as Primary Interface

1. Decision

Keep the Mac as the primary desktop interface.

2. Reason

The Mac provides the keyboard, mouse, display, application environment, and heavier local compute required for the broader system.

C. ADB as the Device Boundary

1. Decision

Use ADB as the primary communication mechanism.

2. Reason

ADB provides an established mechanism for communicating with the physical Android development device without requiring APK modification or custom security-bypass mechanisms.

D. scrcpy as a Development Interaction Mechanism

1. Decision

Use scrcpy where direct visual Android interaction is useful.

2. Reason

It provides practical device interaction during development without defining the entire product around screen mirroring.

E. Separate Current Implementation from Future Worker Architecture

1. Decision

Keep the current device-control system separate from the future distributed compute architecture.

2. Reason

This prevents planned capabilities from being represented as implemented functionality.

⸻

XV. Implementation Status

Component---------------------------------------Status
Native macOS SwiftUI application----------------Implemented
AppState----------------------------------------Implemented
ADBService--------------------------------------Implemented
DeviceManager-----------------------------------Implemented
Physical Pixel 7a connection--------------------Implemented
USB connection path-----------------------------Implemented
Direct wireless ADB path------------------------Implemented
mDNS discovery----------------------------------Implemented
Cancellable device monitoring-------------------Implemented
scrcpy launch-----------------------------------Implemented
Android package discovery-----------------------Implemented
Launcher activity discovery---------------------Implemented
Android metadata retrieval----------------------Implemented
Pixel as distributed AI worker------------------Planned
Resource-aware task routing---------------------Planned
Distributed Mac + Pixel AI workflow-------------Planned
