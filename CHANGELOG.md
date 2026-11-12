# Changelog

All notable changes to ClearMix will be documented in this file.

## [0.5.0] - 2026-11-11
### Added
- Driverless per-application mixer (`AppTap`, `MixerEngine`, `MixerBus`) with `0–200%` boost, soft limiter, mute memory, row pinning, and persistent `System Sounds` (`systemsoundserverd`) control.
- Per-application 10-band stereo peaking equalizer (`Equalizer`) with 7 presets and per-app output routing.
- System output device switcher, hardware-synced Master Volume & Mute, hardware device monitor (`AudioHardwareMonitor`), and auto-ducking during voice calls.
- Real-time RNNoise microphone cleaner (`MicChain`, `MicEngine`) with noise gate, wet/dry strength, `A/B` raw bypass, independent speaker self-monitoring (`MonitorPlayback`), and `BlackHole 2ch` drift-corrected routing.
- 3-step Setup Wizard (`SetupWizardView`) for permissions, `BlackHole 2ch` installation, Bluetooth HFP warning, and live voice testing.
- Optional global hotkeys (`⌃⌥M`, `⌃⌥K`, `⌃⌥D`), right-click row context menus, profiles (`Standard`, `Gaming`, `Meeting`, `Streaming`), Turkish/English UI, and JSON config persistence (`SettingsStore`).
- Per-profile application rules: gain, mute, EQ, pinning and per-app output routing are saved per profile and applied to live taps on switch; the row's output badge opens a device menu and is highlighted when a row plays somewhere other than the main output.
- In-app BlackHole 2ch installation: the setup wizard downloads the official package, verifies its pinned SHA-256 and Existential Audio Developer ID signature, and runs the installer behind macOS's admin prompt.
- One-minute stability test in the Microphone tab (10 s warm-up, then zero underrun/overrun frames to pass) with the result carried in the diagnostics report; the same check is available as `clearmix-mic run --soak <minutes>`.
- Diagnostics report can be saved to a `.txt` file from Settings, next to the clipboard copy.
- Microphone latency work: the engine asks the capture device for a 256-frame IO buffer (restored on stop) and holds a 4 ms capture-ring target, bringing the estimate from ~55 ms to ~34–47 ms.

### Fixed
- Fixed stereo underrun zero-padding frame stride bug (`* channels`) and separated stereo sample-rate conversion (`leftConverter` / `rightConverter`) in `AppTap` so non-48 kHz output devices (such as Bluetooth headphones) play cleanly without channel scrambling.
- Fixed parent application bundle/name/icon resolution for helper processes (such as Chrome Helper and WebKit GPU processes).
