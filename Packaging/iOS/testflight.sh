#!/bin/zsh
# Builds Orihon for iOS devices, signs it for the App Store and uploads it to TestFlight.
# usage: Packaging/iOS/testflight.sh <build-number> [--no-upload]
#
# SwiftPM has no app-bundle step, so this assembles the bundle by hand: release binary → Info.plist template →
# compiled app icon → App Store provisioning profile → codesign → IPA → altool upload. Signing assets (dedicated
# keychain, profile) live in ~/.appstoreconnect/orihon-signing, the App Store Connect API key in
# ~/.appstoreconnect/private_keys. The account's identifiers stay out of the repository (Info.plist and the
# entitlements carry placeholders), in ~/.appstoreconnect/orihon-signing/ship.env:
#   IDENTITY="Apple Distribution: <name> (<team id>)"
#   API_KEY=<App Store Connect API key id>
#   API_ISSUER=<App Store Connect issuer id>
#   BUNDLE_ID=<the app's bundle id>
#   TEAM_ID=<team id>
set -euo pipefail

BUILD=${1:?usage: testflight.sh <build-number> [--no-upload]}
UPLOAD=${2:-}
REPO=${0:A:h:h:h}
PKG=$REPO/Packaging/iOS
W=$REPO/.build/testflight/$BUILD
K=$HOME/.appstoreconnect/orihon-signing
KC=$K/signing.keychain-db
[[ -r $K/ship.env ]] || { echo "missing $K/ship.env (IDENTITY, API_KEY, API_ISSUER, BUNDLE_ID, TEAM_ID)" >&2; exit 1; }
source $K/ship.env
: ${IDENTITY:?} ${API_KEY:?} ${API_ISSUER:?} ${BUNDLE_ID:?} ${TEAM_ID:?}

echo "== build (release, iphoneos)"
CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache swift build -c release --disable-sandbox --package-path $REPO \
  --triple arm64-apple-ios17.0 \
  --sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk \
  -Xswiftc -module-cache-path -Xswiftc /tmp/swift-module-cache --product MihonApp 2>&1 | grep -E "error|Build complete"

echo "== assemble"
rm -rf $W && mkdir -p $W/Orihon.app
# SwiftPM records the deployment target as the SDK version; App Store Connect requires the real SDK (27.1).
xcrun vtool -set-build-version ios 17.0 27.1 -replace -output $W/Orihon.app/MihonApp \
  $REPO/.build/out/Products/Release-iphoneos/MihonApp 2>/dev/null
chmod +x $W/Orihon.app/MihonApp
xcrun actool $PKG/Assets.xcassets --compile $W/Orihon.app --platform iphoneos \
  --minimum-deployment-target 17.0 --app-icon AppIcon --output-partial-info-plist $W/partial.plist \
  --target-device iphone --target-device ipad --output-format human-readable-text --errors >/dev/null
cp $PKG/Info.plist $W/Orihon.app/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" \
  -c "Set :CFBundleIdentifier $BUNDLE_ID" \
  -c "Set :BGTaskSchedulerPermittedIdentifiers:0 $BUNDLE_ID.libraryUpdate" $W/Orihon.app/Info.plist
plutil -convert binary1 $W/Orihon.app/Info.plist
cp $K/AppStore.mobileprovision $W/Orihon.app/embedded.mobileprovision
cp $PKG/entitlements.plist $W/entitlements.plist
/usr/libexec/PlistBuddy -c "Set :application-identifier $TEAM_ID.$BUNDLE_ID" \
  -c "Set :com.apple.developer.team-identifier $TEAM_ID" $W/entitlements.plist
# The profile must be the one for this app id.
PROFILE_APP_ID=$(security cms -D -i $W/Orihon.app/embedded.mobileprovision | plutil -extract Entitlements.application-identifier raw -)
[[ "$PROFILE_APP_ID" == "$TEAM_ID.$BUNDLE_ID" ]] || { echo "profile is for $PROFILE_APP_ID, not $TEAM_ID.$BUNDLE_ID" >&2; exit 1; }

echo "== sign"
# codesign only finds the certificate chain through the user's keychain search list: add the signing keychain
# for the duration of the signature, then restore the original list.
ORIG=("${(@f)$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')}")
security list-keychains -d user -s "$KC" "${ORIG[@]}"
security unlock-keychain -p "$(cat $K/keychain.pass)" "$KC"
codesign --force --sign "$IDENTITY" --keychain "$KC" --entitlements $W/entitlements.plist \
  --generate-entitlement-der --timestamp=none $W/Orihon.app || { security list-keychains -d user -s "${ORIG[@]}"; exit 1; }
security list-keychains -d user -s "${ORIG[@]}"
codesign --verify --strict $W/Orihon.app
mkdir -p $W/Payload && ditto $W/Orihon.app $W/Payload/Orihon.app
(cd $W && zip -qry Orihon.ipa Payload)
echo "ipa: $W/Orihon.ipa (build $BUILD)"

if [[ "$UPLOAD" != "--no-upload" ]]; then
  echo "== validate + upload"
  xcrun altool --validate-app -f $W/Orihon.ipa -t ios --apiKey $API_KEY --apiIssuer $API_ISSUER 2>&1 | grep -E "SUCCEEDED|ERROR|error" | head -5
  xcrun altool --upload-app -f $W/Orihon.ipa -t ios --apiKey $API_KEY --apiIssuer $API_ISSUER 2>&1 | grep -E "SUCCEEDED|Delivery UUID|ERROR|error" | head -5
fi
