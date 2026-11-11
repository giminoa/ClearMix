#!/bin/bash
# Builds the signed app bundles:
#
#   build/ClearMix.app         menu bar app (clearmix-ui)
#   build/clearmix-mix.app     command line mixer probe (clearmix-mix)
#
# Process taps only return audio when the calling process carries
# NSAudioCaptureUsageDescription; a bare binary has no Info.plist and macOS
# answers with silence. Run the bundled apps, not the ones in .build/.
set -euo pipefail

cd "$(dirname "$0")/.."

# `swift build --product` misparses on this toolchain, so build everything.
swift build -c release
bin="$(swift build -c release --show-bin-path)"

bundle() {
    local binary="$1" executable="$2" bundle="$3" plist="$4"
    mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
    cp "$bin/$binary" "$bundle/Contents/MacOS/$executable"
    cp "$plist" "$bundle/Contents/Info.plist"
    if [ -f Resources/AppIcon.icns ]; then
        cp Resources/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
    fi
    # Ad-hoc signature: enough for TCC to attribute the bundle and record a choice.
    codesign --force --deep --sign - "$bundle" >/dev/null
    echo "$bundle hazır."
}

bundle clearmix-ui ClearMix build/ClearMix.app Resources/AppInfo.plist
bundle clearmix-mix ClearMixMix build/clearmix-mix.app Resources/Info.plist

echo "Uygulama: open -n build/ClearMix.app"
echo "CLI:      open -n build/clearmix-mix.app --args list"
