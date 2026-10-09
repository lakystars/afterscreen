#!/bin/zsh
# Builds build/Afterscreen.app (sender, arm64, macOS 14+) and
# build/Afterscreen Receiver.app (universal, macOS 10.15+ Intel / 11+ Apple Silicon).
# Signs with $AFTERSCREEN_SIGN_IDENTITY, or ad-hoc when unset.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
VERSION="${AFTERSCREEN_VERSION:-0.1.0}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
IDENTITY="${AFTERSCREEN_SIGN_IDENTITY:--}"

mkdir -p "$OUT"

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
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>$4</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>Afterscreen connects the sender and receiver over Thunderbolt, USB or Wi-Fi.</string>
    <key>NSBonjourServices</key><array><string>_afterscreen._tcp</string></array>
$5
</dict>
</plist>
PLIST
}

bundle() { # app-path executable-src executable-name plist-content
    rm -rf "$1"
    mkdir -p "$1/Contents/MacOS" "$1/Contents/Resources"
    cp "$2" "$1/Contents/MacOS/$3"
    print -r -- "$4" > "$1/Contents/Info.plist"
    print -n "APPL????" > "$1/Contents/PkgInfo"
    codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$1" >/dev/null
}

print "== Sender"
swift build -c release --package-path "$ROOT/Sender" >/dev/null
SENDER_BIN="$(swift build -c release --package-path "$ROOT/Sender" --show-bin-path)/AfterscreenSender"
bundle "$OUT/Afterscreen.app" "$SENDER_BIN" Afterscreen \
    "$(plist Afterscreen io.github.lakystars.afterscreen.sender Afterscreen 14.0 '    <key>NSScreenCaptureUsageDescription</key><string>Afterscreen captures its virtual display to show it on the receiver.</string>')"

# SwiftPM in current Xcode only targets macOS 12+, so the receiver is built with swiftc directly
build_receiver() { # arch min-os
    local dir="$OUT/receiver-$1" target="$1-apple-macos$2"
    mkdir -p "$dir"
    local flags=(-target "$target" -sdk "$SDK" -O -whole-module-optimization)
    swiftc "${flags[@]}" -parse-as-library -module-name AfterscreenCore -emit-module -emit-module-path "$dir/AfterscreenCore.swiftmodule" \
        -emit-library -static -o "$dir/libAfterscreenCore.a" "$ROOT"/Core/Sources/AfterscreenCore/*.swift
    swiftc "${flags[@]}" -parse-as-library -module-name AfterscreenReceiverKit -I "$dir" -emit-module -emit-module-path "$dir/AfterscreenReceiverKit.swiftmodule" \
        -emit-library -static -o "$dir/libAfterscreenReceiverKit.a" "$ROOT"/Receiver/Sources/AfterscreenReceiverKit/*.swift
    swiftc "${flags[@]}" -I "$dir" -L "$dir" -lAfterscreenReceiverKit -lAfterscreenCore \
        -framework AppKit -framework Metal -framework QuartzCore -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework IOKit \
        -o "$dir/AfterscreenReceiver" "$ROOT/Receiver/Sources/AfterscreenReceiver/main.swift"
}

print "== Receiver (x86_64, macOS 10.15)"
build_receiver x86_64 10.15
print "== Receiver (arm64, macOS 11)"
build_receiver arm64 11.0
lipo -create "$OUT/receiver-x86_64/AfterscreenReceiver" "$OUT/receiver-arm64/AfterscreenReceiver" -output "$OUT/AfterscreenReceiver-universal"
bundle "$OUT/Afterscreen Receiver.app" "$OUT/AfterscreenReceiver-universal" "Afterscreen Receiver" \
    "$(plist 'Afterscreen Receiver' io.github.lakystars.afterscreen.receiver 'Afterscreen Receiver' 10.15 '')"

codesign --verify --strict "$OUT/Afterscreen.app" "$OUT/Afterscreen Receiver.app"
print "== Done"
print "  $OUT/Afterscreen.app"
print "  $OUT/Afterscreen Receiver.app ($(lipo -archs "$OUT/AfterscreenReceiver-universal"))"
