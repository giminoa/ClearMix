# Third-Party Notices

ClearMix includes or integrates with the following third-party open-source projects:

## 1. RNNoise (bundled in `Sources/CMixRNNoise/vendor`)
- **Upstream:** https://github.com/xiph/rnnoise
- **License:** BSD 3-Clause License (see `Sources/CMixRNNoise/vendor/COPYING`)
- **Copyright:**
  - Copyright (c) 2017–2018 Mozilla, Gregor Richards, Jean-Marc Valin
  - Copyright (c) 2003–2011 Xiph.Org Foundation, CSIRO, Octasic Inc., Mark Borgerding

## 2. BlackHole 2ch (optional external system driver)
- **Upstream:** https://github.com/ExistentialAudio/BlackHole
- **License:** GPL-3.0
- **Note:** BlackHole is **not** linked into or redistributed inside ClearMix binaries. Users install it separately (for example via `brew install --cask blackhole-2ch`) if they want to route the denoised microphone output into Discord, Zoom, or OBS as a virtual microphone.

## 3. Architectural Inspiration
- ClearMix's driverless per-application Core Audio process tap approach (`AudioHardwareCreateProcessTap`) was inspired by MIT-licensed **Fabar** (github.com/gigaptera/fabar).
