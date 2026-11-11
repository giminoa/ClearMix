# AGENTS.md

Guidelines for contributors and coding agents working on **ClearMix**.

## Architecture
- `Sources/CMixRT`: C helpers for lock-free realtime audio primitives.
- `Sources/CMixRNNoise`: Vendored RNNoise C library and minimal C bridge.
- `Sources/ClearMixCore`: UI-independent Swift audio engine (`Audio`, `DSP`, `Mic`, `Mixer`, `Config`).
- `Sources/ClearMixUI`: SwiftUI / AppKit menu bar application (`clearmix-ui`).
- `Sources/ClearMixDSP`, `Sources/ClearMixMic`, `Sources/ClearMixMix`: CLI test & diagnostic tools.
- `Tests/ClearMixCoreTests`: XCTest suite covering ring buffers, resampling, denoiser, dynamics, EQ, mixer buses, and config persistence.

## Real-Time Audio Thread Rules (Mandatory)
Code executing inside Core Audio capture/render callbacks (`AppTap`, `MicEngine`, `MonitorPlayback`) and DSP `process` paths MUST NEVER:
1. Allocate or free heap memory (`Array`, `Data`, Swift closures capturing objects, `malloc`/`free`). Pre-allocate scratch buffers in `init`.
2. Acquire locks or mutexes (`os_unfair_lock`, `NSLock`, `DispatchSemaphore`, Swift `actor`/ObjC `@synchronized`). Use SPSC lock-free `AudioRingBuffer` and atomic/trival snapshots.
3. Perform logging (`print`, `os_log`/`Logger`), file I/O, or spawn `Task` / `DispatchQueue` work items.
4. Trigger Swift retain/release or `String` formatting. Work on raw `UnsafeMutablePointer<Float>` and `Accelerate` (`vDSP`).

## Workflow & Verification
- Keep changes small, modular, and test-driven.
- Whenever modifying `ClearMixCore`, run `swift test` and ensure 100% of `ClearMixCoreTests` pass.
- Whenever modifying `ClearMixUI` or build configuration, verify both `swift test` and `./Scripts/bundle-app.sh`.
- Preserve backward compatibility in `ClearMixSettings` JSON decoding via `decodeIfPresent`.
