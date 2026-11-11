# Changelog

All notable changes to ClearMix will be documented in this file.

## [0.5.0] - 2026-11-11
### Added
- Driverless per-application mixer (`AppTap`, `MixerEngine`, `MixerBus`) with `0–200%` boost, soft limiter, mute memory, row pinning, and persistent `System Sounds` (`systemsoundserverd`) control.
- Per-application 10-band stereo peaking equalizer (`Equalizer`) with 7 presets and per-app output routing.
- System output device switcher, hardware-synced Master Volume & Mute, hardware device monitor (`AudioHardwareMonitor`), and auto-ducking during voice calls.
- Real-time RNNoise microphone cleaner (`MicChain`, `MicEngine`) with noise gate, wet/dry strength, `A/B` raw bypass, independent speaker self-monitoring (`MonitorPlayback`), and `BlackHole 2ch` drift-corrected routing.
- 3-step Setup Wizard (`SetupWizardView`) for permissions, `BlackHole 2ch` installation, Bluetooth HFP warning, and live voice testing.
- Optional global hotkeys (`⌃⌥M`, `⌃⌥K`, `⌃⌥D`), right-click row context menus, profiles (`Standard`, `Gaming`, `Meeting`, `Streaming`), Turkish/English UI, diagnostics export, and JSON config persistence (`SettingsStore`).

### Fixed
- Fixed stereo underrun zero-padding frame stride bug (`* channels`) and separated stereo sample-rate conversion (`leftConverter` / `rightConverter`) in `AppTap` so non-48 kHz output devices (such as Bluetooth headphones) play cleanly without channel scrambling.
- Fixed parent application bundle/name/icon resolution for helper processes (such as Chrome Helper and WebKit GPU processes).
