PixelDesktop is a native macOS application for controlling and coordinating a physical Android device as a local compute node.

The project uses a MacBook as the primary desktop interface and a physical Google Pixel 7a as the Android-side device. The Pixel is treated as a real connected device rather than an Android emulator.

⸻

Table of Contents

1. I. Overview
    * A. Project Description
    * B. Current Status
2. II. System Architecture
    * A. High-Level Architecture
    * B. System Roles
3. III. Current Capabilities
    * A. Device Management
    * B. Android Discovery
    * C. Device Interaction
    * D. Metadata
4. IV. Core Components
    * A. AppState
    * B. ADBService
    * C. DeviceManager
5. V. Android Device
    * A. Physical Device
    * B. Role in the System
6. VI. Communication
    * A. ADB
    * B. USB
    * C. Wireless ADB
    * D. mDNS
7. VII. Development Constraints
8. VIII. Verification
9. IX. Future Direction
    * A. Compute Worker
    * B. Distributed Architecture
10. X. Technologies
11. XI. Documentation

⸻

I. Overview

A. Project Description

PixelDesktop is a native macOS application designed to control and coordinate a physical Android device as a local compute node.

The project uses:

* A MacBook as the primary desktop environment
* A physical Google Pixel 7a as the Android-side device
* ADB as the primary device communication mechanism
* SwiftUI as the macOS user interface

The Pixel 7a is treated as an actual physical computing device rather than an Android emulator.

B. Current Status

Status: Active development

The current implementation establishes the foundation for communicating with and managing the physical Pixel 7a.

Implemented areas include:

* Device discovery
* ADB communication
* Device monitoring
* USB and direct wireless connection paths
* mDNS discovery
* Android package discovery
* Launcher activity discovery
* Android metadata retrieval
* scrcpy integration

The longer-term direction is to use the Pixel 7a as a specialized local compute worker while the Mac remains responsible for the primary interface, planning, orchestration, and heavier reasoning.

⸻

II. System Architecture

A. High-Level Architecture

                 MacBook
        ┌─────────────────────┐
        │     PixelDesktop    │
        │      SwiftUI App    │
        ├─────────────────────┤
        │ AppState            │
        │ DeviceManager       │
        │ ADBService          │
        └──────────┬──────────┘
                   │
              ADB / mDNS
                   │
                   ▼
        ┌─────────────────────┐
        │     Pixel 7a        │
        │     Android 16      │
        │  Physical Device    │
        └─────────────────────┘

PixelDesktop provides the macOS-side control and coordination layer, while the Pixel provides the Android-side environment and physical computing resources.

B. System Roles

A. MacBook

The MacBook serves as the primary:

* Desktop interface
* Keyboard and mouse environment
* PixelDesktop application host
* Planning environment
* Orchestration environment

The Mac is also expected to handle heavier models and more complex reasoning in the future architecture.

B. Pixel 7a

The Pixel 7a serves as the Android-side device and future specialized compute worker.

It provides its own:

* CPU
* GPU
* RAM
* Storage
* Android runtime

The project does not attempt to combine the Mac and Pixel’s physical RAM into one shared memory pool.

⸻

III. Current Capabilities

A. Device Management

PixelDesktop currently provides:

* Physical Pixel 7a support
* Device discovery
* Connection management
* USB connection support
* Direct wireless connection support
* mDNS discovery
* Device availability monitoring
* Cancellable three-second monitoring

B. Android Discovery

The application can inspect the Android environment and discover:

* Android packages
* Launcher activities
* Device information
* Application metadata

During development, PixelDesktop successfully discovered 82 launcher activities on the connected Pixel 7a.

This is an observed development result and is not a fixed system limit.

C. Device Interaction

PixelDesktop integrates scrcpy for practical interaction with the physical Android device.

scrcpy is useful during development and device interaction, but whole-screen mirroring is not the intended final endpoint of PixelDesktop.

The project is intended to provide higher-level device control and access to useful device capabilities.

D. Metadata

PixelDesktop can retrieve Android-side metadata through ADB.

The current metadata workflow uses:

* run-as
* metadata.json

This provides a way to retrieve permitted application metadata without introducing a separate HTTP server solely for metadata transfer.

⸻

IV. Core Components

A. AppState

AppState is the main observable application state layer.

It:

* Uses @MainActor
* Uses @Observable
* Coordinates application state used by the SwiftUI interface

B. ADBService

ADBService is an actor responsible for ADB-related operations.

It isolates asynchronous device communication from the main UI execution context.

C. DeviceManager

DeviceManager is an actor responsible for device discovery and monitoring.

Its responsibilities include:

* Device discovery
* Connection management
* USB/direct-wireless connection preference
* mDNS discovery
* Device availability monitoring

The current monitoring loop uses a cancellable three-second interval.

⸻

V. Android Device

A. Physical Device

PixelDesktop uses a physical Google Pixel 7a running Android 16.

The device is not an emulator.

This allows the project to work with the actual hardware and Android environment of the device.

B. Role in the System

The Pixel currently functions as the Android-side device controlled by PixelDesktop.

Its longer-term role is to become a specialized local compute worker capable of handling workloads appropriate for its available resources.

⸻

VI. Communication

A. ADB

Android Debug Bridge is the primary communication mechanism between PixelDesktop and the Pixel 7a.

ADB is used for:

* Device communication
* Device inspection
* Package discovery
* Activity discovery
* Metadata retrieval
* Supported device interactions

B. USB

USB provides a local connection path between the Mac and Pixel.

The project favors USB when available because it avoids some of the reliability issues encountered with wireless ADB.

C. Wireless ADB

Direct wireless ADB provides an additional connection path.

Wireless ADB experienced connection and disconnection reliability issues during development, so the architecture does not assume that wireless connectivity is always stable.

D. mDNS

mDNS is used as part of device discovery for supported network discovery scenarios.

⸻

VII. Development Constraints

PixelDesktop is intentionally designed without:

* APK modification
* Code injection
* Anti-cheat bypasses
* Destructive Android operations
* Security-bypass mechanisms

The project works with the physical Android device through supported device-control and development mechanisms.

The development sandbox was also removed because Homebrew ADB did not function correctly inside the sandbox environment.

⸻

VIII. Verification

Development verification has included:

* Project builds
* Application launch at working checkpoints
* Device discovery
* ADB communication
* Android package discovery
* Launcher activity discovery
* Metadata retrieval
* scrcpy launch
* Five tests passing at a development checkpoint

No automated test coverage percentage is claimed.

⸻

IX. Future Direction

A. Compute Worker

The long-term goal is to use the Pixel 7a as a specialized local compute worker while the Mac handles more complex work.

Potential Pixel-side workloads include:

* Small local AI models
* Lightweight coding tasks
* Small code edits
* Script execution
* Local code analysis
* Test execution
* Other constrained workloads appropriate for the device

The Pixel is intended to be a specialized worker rather than the primary reasoning system.

B. Distributed Architecture

A future version may use resource-aware task routing.

Task
 │
 ▼
Task Classification
 │
 ▼
Capability / Resource Check
 │
 ├───────────────┐
 ▼               ▼
Mac              Pixel
 │               │
Heavy /          Lightweight /
complex work     constrained work
 │               │
 └───────┬───────┘
         ▼
       Result

The Mac is intended to handle:

* Architecture
* Planning
* Complex reasoning
* Orchestration
* Heavier workloads

The Pixel may handle:

* Lightweight AI workloads
* Small coding tasks
* Scripts
* Local analysis
* Tests

This distributed task-routing architecture is planned and is not currently implemented.

⸻

X. Technologies

* Swift
* SwiftUI
* macOS
* Xcode
* Android
* Android Debug Bridge (ADB)
* mDNS
* scrcpy

⸻

XI. Documentation

For the detailed technical architecture, see:

* Architecture Documentation
