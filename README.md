# Afterscreen

Use an older iMac (Late 2013 or newer) as a wired external display for an Apple Silicon Mac, at the iMac's native resolution and 60 fps. Both apps live in the menu bar and show live link, frame and resource telemetry.

- 5120×2880 at 60 fps on 5K iMacs over Thunderbolt Bridge or USB networking
- Up to 3840×2160 at 60 fps over Wi-Fi
- Only Apple frameworks, no third-party dependencies

## How it works

| Link | Picture path |
|---|---|
| Thunderbolt Bridge, USB networking | **Tiles**: the sender encodes the regions ScreenCaptureKit reports as changed into BC7 texture blocks on the GPU and sends the 64×64 tiles that differ, grouped into runs. Tiles that keep changing go out as BC1 at half the size, and their BC7 version follows once they settle. The receiver blits each run straight into a BC7 texture. Every Mac GPU since 2013 samples BC7 in hardware, so no video decoder is needed and there is no codec latency. LZ4 is used only when a frame would not fit the link otherwise. |
| Wi-Fi | **Video**: VideoToolbox HEVC, or H.264 when the receiver has no HEVC decoder. Real-time, no frame reordering. |

The sender creates a virtual display at the receiver's panel resolution, captures it with ScreenCaptureKit, and streams over TCP. Receivers announce themselves over Bonjour (`_afterscreen._tcp`). The sender picks the route by interface: Thunderbolt, then USB, then Wi-Fi. A short throughput probe at session start decides between tiles and video.

## Requirements

| | Sender | Receiver |
|---|---|---|
| Hardware | Apple Silicon Mac | iMac Late 2013 or newer (Intel or Apple Silicon) |
| macOS | 14 Sonoma or newer | 10.15 Catalina or newer |
| Permissions | Screen Recording, Local Network | Local Network |

Ethernet and other links are refused. v1 is an extended display only: no mirroring, audio or keyboard/mouse relay.

## Build

Requires Xcode with the macOS SDK on an Apple Silicon Mac.

```sh
zsh scripts/build_apps.sh
```

This produces:

- `build/Afterscreen.app`: the sender (arm64, macOS 14+)
- `build/Afterscreen Receiver.app`: the receiver (universal, macOS 10.15+)

Set `AFTERSCREEN_SIGN_IDENTITY` to a code-signing identity to sign with it. Otherwise the apps are signed ad hoc.

The receiver is compiled with `swiftc` directly, because current SwiftPM refuses deployment targets below macOS 12. The Swift packages are used for tests:

```sh
swift test --package-path Core
swift test --package-path Sender
swift test --package-path Receiver
```

## Faster Thunderbolt links

Thunderbolt Bridge uses a 1500-byte MTU by default. Jumbo frames cut the packets per second each Mac handles about sixfold. Set it on both Macs, then reconnect:

```sh
sudo networksetup -setMTU "Thunderbolt Bridge" 9000
```

The popover shows the link's MTU and suggests 9000 when it is lower.

## Usage

1. Connect the Macs with a Thunderbolt cable (Thunderbolt Bridge) or a USB-C cable (USB networking). Wi-Fi also works.
2. Start **Afterscreen Receiver** on the iMac. Allow Local Network access.
3. Start **Afterscreen** on the Apple Silicon Mac. Allow Local Network access and Screen Recording.
4. Click the ▭ menu bar item and choose **Connect** next to the iMac.

The iMac switches to a fullscreen picture of the new display. On the receiver:

- ⌥⌘I toggles the HUD
- Esc twice stops the session

## Telemetry

The sender's menu bar shows the link glyph, sent frame rate and throughput, for example `▭ ϟ 60fps · 2.4G`. The popover lists:

| Field | Meaning |
|---|---|
| Method | Link type and local interface (ϟ Thunderbolt, ⌁ USB, ≋ Wi-Fi, ↺ same Mac) |
| MTU | Link MTU; 9000 is recommended on Thunderbolt and USB |
| Cable quality | 0–100. Starts at 100, minus up to 40 for TCP retransmits, up to 30 for jitter, up to 30 for probe capacity below what the stream needs. |
| Throughput | Bytes sent per second, with a trend line |
| Latency (RTT) | Kernel smoothed TCP round trip on the stream connection |
| Jitter | Kernel TCP round-trip variance |
| Capacity (probe) | Throughput measured at session start |
| Retransmits | TCP retransmitted packets as a share of packets sent |
| Capture → sent → shown | Frames per second captured, sent and displayed by the receiver |
| Dropped / min | Captured frames replaced by a newer one before they could be sent |
| Path | Tiles (BC7) or video codec, with stream resolution |
| Changed tiles | Share of tiles resent over the last second |
| Compression | Raw BC7 bytes ÷ bytes sent; 1.0× when the link carries frames uncompressed |
| Encode | GPU encode time (tiles) or encoder submit time (video) |
| CPU · RAM · GPU | This app's own use, on each side |
| Upload · decompress | Receiver texture upload and LZ4 time per frame |
| Hardware | Receiver model, panel, GPU, macOS and decoders |

## Performance

At 5K on one Apple M5 Pro over loopback, a full-screen moving picture costs the sender about 20% of one core and the receiver about 14%, mostly kernel socket copying, at 3.2 Gbps. See [docs/Performance.md](docs/Performance.md) for the method, the bench and before/after numbers.

## Status

v1. Verified with automated tests and with both apps on one Mac (see [docs/Testing.md](docs/Testing.md)). Not yet verified on a real iMac, on macOS 10.15, or over USB networking.

## License

MIT. See [LICENSE](LICENSE).
