# ClearMix

**Open-source macOS menu bar audio mixer & real-time microphone noise suppressor.**  
*Sürücüsüz uygulama bazlı ses mikseri + RNNoise & BlackHole tabanlı mikrofon gürültü temizleyici (Türkçe / English).*

- **100% Local & Privacy-First:** Zero telemetry, zero cloud calls.
- **Requires:** macOS 14.4+ (Sonoma or newer), Swift 6.0 / Xcode 16+.

---

## Features / Özellikler

### Per-App System Audio Mixer (Driverless)
- Controls volume (`0–200%` boost with soft limiter) and mute state per running application via Core Audio Process Taps (`AudioHardwareCreateProcessTap`).
- Persistent **System Sounds** (`systemsoundserverd`) control, row pinning, and per-app output device routing (e.g., browser on speakers, game on headphones).
- **10-Band Stereo Equalizer** per app with 7 presets (`Flat`, `Bass Boost`, `Vocal`, `Podcast`, `Gaming`, `Treble`, `Night`).
- **Master Volume & Output Device Switcher** synced with macOS hardware volume keys.
- **Auto-Ducking** when voice apps (Discord, Zoom, Slack, FaceTime) are active.
- Preserves mute slider position and saves rules in `~/Library/Application Support/ClearMix/settings.json`.

### Real-Time Microphone Noise Suppression
- **RNNoise** neural speech denoiser at 48 kHz (`10 ms` / `480`-sample frames) with wet/dry strength (`0–100%`).
- **Noise Gate** with adjustable threshold (`-70` to `-20 dB`) and mic gain (`-12` to `+18 dB`).
- **Before / After (`Önce / Sonra`) live meters**, instant **A/B raw bypass**, and **Self-Monitor (`Kendimi duy`)** routed to your speakers/headphones while keeping the virtual mic clean.
- Automatic clock-drift compensation (`DriftController`) between physical microphone and `BlackHole 2ch`.
- **3-Step Setup Wizard** for permissions, BlackHole 2ch detection, Bluetooth headset tips, and Discord/Zoom/OBS setup.
- **Global Hotkeys (optional):** `⌃⌥M` Master Mute, `⌃⌥K` Toggle Mic, `⌃⌥D` Toggle Denoise.
- **Bilingual UI:** Turkish (`Türkçe`) & English.

---

## Architecture / Mimari

```text
SYSTEM AUDIO (Driverless Process Taps)
  App Audio ──▶ CoreAudio Tap + Aggregate ──▶ Equalizer / Gain / Mute ──▶ Selected Output Device

MICROPHONE CLEANER (Real-Time)
  Mic Input ──▶ AUHAL ──▶ SPSC Ring ──▶ 48kHz Mono ──▶ RNNoise + Gate ──┬──▶ BlackHole 2ch (Discord/Zoom/OBS)
                                                                       └──▶ Speakers (Optional Self-Monitor)
```

Targets defined in [Package.swift](Package.swift):
- `CMixRT`: C realtime lock-free primitives
- `CMixRNNoise`: Vendored RNNoise C library + Swift-friendly wrapper
- `ClearMixCore`: UI-independent audio engine, DSP, mixer, mic chain, config store
- `ClearMixUI`: Menu bar SwiftUI/AppKit application (`build/ClearMix.app`)
- `ClearMixMix`, `ClearMixMic`, `ClearMixDSP`: CLI inspection & offline/live test utilities

---

## Quick Start / Kurulum

### 1. Optional: Install BlackHole 2ch (Virtual Microphone)
If you want Discord, Zoom, or OBS to receive your cleaned microphone audio (not required if you only use the per-app mixer):

```bash
brew install --cask blackhole-2ch
```

Then select **BlackHole 2ch** as your **Input Device** inside Discord / Zoom / OBS.

> **Bluetooth Headset Tip:** Opening a Bluetooth headset's built-in microphone switches macOS into lower-quality HFP mode. For best quality, use your Mac's built-in mic or a USB mic as input and keep your Bluetooth headphones as output only.

### 2. Build & Bundle ClearMix

```bash
git clone https://github.com/<your-username>/ClearMix.git
cd ClearMix
./Scripts/bundle-app.sh
open -n build/ClearMix.app
```

### 3. Run Unit Tests

```bash
swift test
```

---

## CLI Utilities

You can inspect audio processes, devices, or test DSP pipelines from the terminal:

```bash
swift run clearmix-mix list --all
swift run clearmix-mic --list
swift run clearmix-dsp --help
```

---

---

## Performance (measured) / Ölçülen Performans

| Metric | Target | Measured |
| --- | --- | --- |
| App start (process launch) | < 1 s | 0.42 s |
| Idle CPU, no audio tapped | ~1 % | 0.0-0.1 % |
| Memory, idle | < 60 MB | 23-25 MB |
| Mic chain latency (estimate) | < 40 ms average | 34-47 ms, avg ~39 ms |
| Stability, 3-minute soak | no glitches | passed: 0 underrun/overrun after 10 s warm-up |

Measuring: `ps -o %cpu=,rss= -p <pid>` for the app, and `clearmix-mic run --mute --soak <minutes>`
for the microphone chain (silent, so it is safe during a call).

## License

- ClearMix source code: [MIT License](LICENSE)
- Third-party notices (RNNoise BSD-3-Clause, external BlackHole GPL-3.0 note): [THIRD_PARTY.md](THIRD_PARTY.md)
