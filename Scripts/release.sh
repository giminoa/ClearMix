#!/bin/bash
# One-command signed release for ClearMix.
#
# Until a paid Apple Developer membership exists, `bundle-app.sh` signs ad-hoc.
# This script signs with a Developer ID Application certificate, enables the
# hardened runtime, builds a DMG, notarizes it, staples the ticket and checks it
# with Gatekeeper — everything Apple requires for a download users can open.
#
# One-time setup (after the membership is active):
#
#   xcrun notarytool store-credentials clearmix-notary \
#       --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
#
#   security find-identity -v -p codesigning        # copy the Developer ID Application identity
#   export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"
#
# Then, for every release:
#
#   NOTARY_PROFILE=clearmix-notary ./Scripts/release.sh
#
# Environment:
#   DEVELOPER_ID_APPLICATION  codesign identity (required)
#   NOTARY_PROFILE            notarytool keychain profile (default: clearmix-notary)
#   SKIP_NOTARIZATION=1       sign only, for local verification of the signature
set -euo pipefail

cd "$(dirname "$0")/.."

identity="${DEVELOPER_ID_APPLICATION:-}"
profile="${NOTARY_PROFILE:-clearmix-notary}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/AppInfo.plist)"
app="build/ClearMix.app"
dist="build/dist"
dmg="$dist/ClearMix-$version.dmg"

if [ -z "$identity" ]; then
    cat <<'EOF' >&2
Hata: DEVELOPER_ID_APPLICATION tanımlı değil — imzalama kimliği gerekli.

  security find-identity -v -p codesigning
  export DEVELOPER_ID_APPLICATION="Developer ID Application: Ad Soyad (TEAMID)"

Üyelik yoksa ad-hoc paket için: ./Scripts/bundle-app.sh
EOF
    exit 1
fi

if ! security find-identity -v -p codesigning | grep -qF "$identity"; then
    echo "Hata: '$identity' anahtarlıkta bulunamadı. Geçerli kimlikler:" >&2
    security find-identity -v -p codesigning | tail -n +2 >&2
    exit 1
fi

echo "▸ ClearMix $version imzalanıyor: $identity"
CODESIGN_IDENTITY="$identity" ./Scripts/bundle-app.sh

echo "▸ İmza doğrulanıyor"
codesign --verify --strict --deep --verbose=2 "$app"
codesign -dv --verbose=2 "$app" 2>&1 | grep -E "Authority|Timestamp|TeamIdentifier|Runtime" || true

echo "▸ DMG oluşturuluyor: $dmg"
mkdir -p "$dist"
rm -f "$dmg"
hdiutil create -quiet -volname "ClearMix $version" -srcfolder "$app" -ov -format UDZO "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg" >/dev/null

if [ "${SKIP_NOTARIZATION:-0}" = "1" ]; then
    echo "▸ Notarization atlandı (SKIP_NOTARIZATION=1). Paket: $dmg"
    exit 0
fi

if ! security find-generic-password -s "com.apple.gs.appleid.auth" >/dev/null 2>&1; then
    : # A missing keychain item is not proof either way; notarytool reports it.
fi

echo "▸ Notarization gönderiliyor (birkaç dakika sürebilir): $profile"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait

echo "▸ Bilet DMG'ye stapleniyor"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"

echo "▸ Gatekeeper kontrolü"
spctl --assess --type open --context context:primary-signature -v "$dmg"

# Sparkle-style update archive and the app zip for manual downloads.
ditto -c -k --keepParent "$app" "$dist/ClearMix-$version.zip"

echo ""
echo "Hazır: $dmg"
echo "Yüklemek için: gh release upload v$version \"$dmg\" \"$dist/ClearMix-$version.zip\" --clobber"
