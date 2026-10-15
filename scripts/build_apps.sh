#!/bin/zsh
# Builds build/Afterscreen.app (sender, arm64, macOS 14+) and
# build/Afterscreen Receiver.app (universal, macOS 10.15+ Intel / 11+ Apple Silicon)
# Signs with $AFTERSCREEN_SIGN_IDENTITY, else first Apple Development identity, else ad-hoc
# Ad-hoc signature changes per build: macOS re-asks privacy permissions
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
VERSION="${AFTERSCREEN_VERSION:-0.1.0}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
SDK_VERSION="$(xcrun --show-sdk-version --sdk macosx)"
# Current SwiftUI APIs need Swift concurrency, in macOS from 12
# Receiver bundles the toolchain's back-deployed copy for 10.15, 11
CONCURRENCY="$(dirname "$(dirname "$(xcrun --find swiftc)")")/lib/swift-5.5/macosx/libswift_Concurrency.dylib"
[[ -f "$CONCURRENCY" ]] || { print -u2 "Missing $CONCURRENCY"; exit 1 }
IDENTITY="${AFTERSCREEN_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development/ { print $2; exit }' || true)}"
IDENTITY="${IDENTITY:--}"
print "== Signing identity: $IDENTITY"

mkdir -p "$OUT"

print "== App icons"
rm -rf "$OUT/icon"
swift "$ROOT/scripts/icons.swift" "$OUT/icon"
for role in Sender Receiver; do
    iconutil -c icns "$OUT/icon/$role.iconset" -o "$OUT/icon/$role.icns"
done

plist() { # name bundle-id executable min-os extra-keys
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$1</string>
    <key>CFBundleDisplayName</key><string>$1</string>
    <key>CFBundleIdentifier</key><string>$2</string>
    <key>CFBundleExecutable</key><string>$3</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>$4</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>Afterscreen connects the sender and receiver over Thunderbolt, USB, Ethernet or Wi-Fi.</string>
    <key>NSBonjourServices</key><array><string>_afterscreen._tcp</string></array>
$5
</dict>
</plist>
PLIST
}

bundle() { # app-path executable-src executable-name icon plist-content [dylib...]
    local app="$1" exe="$3"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$2" "$app/Contents/MacOS/$exe"
    cp "$OUT/icon/$4.icns" "$app/Contents/Resources/AppIcon.icns"
    # Symbols only serve debugging; stripped executables are about 45% smaller
    strip "$app/Contents/MacOS/$exe"
    print -r -- "$5" > "$app/Contents/Info.plist"
    print -n "APPL????" > "$app/Contents/PkgInfo"
    shift 5
    local runtime=(--options runtime)
    # Nested code signed before the app
    for lib in "$@"; do
        mkdir -p "$app/Contents/Frameworks"
        cp "$lib" "$app/Contents/Frameworks/"
        codesign --force --timestamp=none --sign "$IDENTITY" "$app/Contents/Frameworks/${lib:t}" >/dev/null
        # No Team ID: library validation would refuse the copy
        if codesign -dv "$app/Contents/Frameworks/${lib:t}" 2>&1 | grep -q '^TeamIdentifier=not set'; then runtime=(); fi
    done
    codesign --force "${runtime[@]}" --timestamp=none --sign "$IDENTITY" "$app" >/dev/null
}

print "== Sender"
SENDER_MIN_OS=14.0
swift build -c release --package-path "$ROOT/Sender" >/dev/null
SENDER_BIN="$(swift build -c release --package-path "$ROOT/Sender" --show-bin-path)/AfterscreenSender"
# SwiftPM's build engine records the deployment target as SDK
# SDK below 26 turns off Liquid Glass on macOS 26+
vtool -set-build-version macos "$SENDER_MIN_OS" "$SDK_VERSION" -replace -output "$OUT/AfterscreenSender" "$SENDER_BIN"
bundle "$OUT/Afterscreen.app" "$OUT/AfterscreenSender" Afterscreen Sender \
    "$(plist Afterscreen io.github.lakystars.afterscreen.sender Afterscreen "$SENDER_MIN_OS" '    <key>NSScreenCaptureUsageDescription</key><string>Afterscreen captures its virtual display to show it on the receiver.</string><key>NSAudioCaptureUsageDescription</key><string>Afterscreen plays the sound of this Mac on the receiver.</string>')"

# SwiftPM in current Xcode targets macOS 12+ only
# Receiver builds with swiftc directly
build_receiver() { # arch min-os
    local dir="$OUT/receiver-$1" target="$1-apple-macos$2"
    mkdir -p "$dir"
    local flags=(-target "$target" -sdk "$SDK" -O -whole-module-optimization)
    swiftc "${flags[@]}" -parse-as-library -module-name AfterscreenCore -emit-module -emit-module-path "$dir/AfterscreenCore.swiftmodule" \
        -emit-library -static -o "$dir/libAfterscreenCore.a" "$ROOT"/Core/Sources/AfterscreenCore/**/*.swift
    swiftc "${flags[@]}" -parse-as-library -module-name AfterscreenReceiverKit -I "$dir" -emit-module -emit-module-path "$dir/AfterscreenReceiverKit.swiftmodule" \
        -emit-library -static -o "$dir/libAfterscreenReceiverKit.a" "$ROOT"/Receiver/Sources/AfterscreenReceiverKit/**/*.swift
    # /usr/lib/swift first: macOS 12+ keeps its own concurrency library
    swiftc "${flags[@]}" -I "$dir" -L "$dir" -lAfterscreenReceiverKit -lAfterscreenCore -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
        -framework AppKit -framework Metal -framework QuartzCore -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework IOKit -framework SystemConfiguration -framework SwiftUI -framework AudioToolbox \
        -o "$dir/AfterscreenReceiver" "$ROOT/Receiver/Sources/AfterscreenReceiver/main.swift"
}

print "== Receiver (x86_64, macOS 10.15)"
build_receiver x86_64 10.15
print "== Receiver (arm64, macOS 11)"
build_receiver arm64 11.0
lipo -create "$OUT/receiver-x86_64/AfterscreenReceiver" "$OUT/receiver-arm64/AfterscreenReceiver" -output "$OUT/AfterscreenReceiver-universal"
bundle "$OUT/Afterscreen Receiver.app" "$OUT/AfterscreenReceiver-universal" "Afterscreen Receiver" Receiver \
    "$(plist 'Afterscreen Receiver' io.github.lakystars.afterscreen.receiver 'Afterscreen Receiver' 10.15 '    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>')" "$CONCURRENCY"

codesign --verify --strict --deep "$OUT/Afterscreen.app" "$OUT/Afterscreen Receiver.app"
print "== Done"
print "  $OUT/Afterscreen.app"
print "  $OUT/Afterscreen Receiver.app ($(lipo -archs "$OUT/AfterscreenReceiver-universal"))"
