# Afterscreen

Use an older iMac (Late 2013 or newer) as an external display for an Apple Silicon Mac, at the iMac's native resolution. Both apps live in the menu bar and show live link, frame and resource telemetry.

- 5120×2880 at 60 fps on 5K iMacs over Thunderbolt Bridge or USB networking, and over Gigabit Ethernet with moving regions as 4K video
- Over Wi-Fi, still content stays lossless at native resolution; moving content goes out as video at the rate the link carries
- Settings for display size, link, sound, menu bar and language (English, Korean); iMac brightness and volume from the Mac
- The Mac's sound plays on the iMac's speakers (macOS 14.2 or newer on the sender)
- A quality test that measures the highest resolution and frame rate the link sustains
- Only Apple frameworks, no third-party dependencies

## How it works

| Link | Picture path |
|---|---|
| Wired, 2.5 Gbps or more (Thunderbolt Bridge, USB networking, fast Ethernet) | **Tiles**: the sender encodes the regions ScreenCaptureKit reports as changed into BC7 texture blocks on the GPU and sends the 64×64 tiles that differ, grouped into runs. Tiles that keep changing go out as BC1 at half the size, and their BC7 version follows once they settle. The receiver blits each run straight into a BC7 texture. Every Mac GPU since 2013 samples BC7 in hardware, so no video decoder is needed and there is no codec latency. LZ4 is used only when a frame would not fit the link otherwise. |
| Slower links (Gigabit Ethernet, Wi-Fi) | **Hybrid**: still and briefly changing tiles go out as BC7, as above. Tiles that keep moving switch to a video layer (VideoToolbox HEVC, or H.264 when the receiver has no HEVC decoder) and return to BC7 once they settle. The receiver draws the video in those tiles and the BC7 picture elsewhere. The video layer is 4K, 1440p or 1080p, whichever the link's bitrate fills at 0.15 bit per pixel. |

The sender creates a virtual display at the receiver's panel resolution, captures it with ScreenCaptureKit in 10-bit, and streams over TCP. Tiles dither the extra precision into BC7, so gradients do not band; the video layer is HEVC Main10 when the receiver decodes it in hardware. The cursor travels on a second connection of its own, so it never waits behind frames. Receivers announce themselves over Bonjour (`_afterscreen._tcp`). On connect the sender asks for the receiver on each of its links and prefers Thunderbolt, then USB, Ethernet and Wi-Fi; the popover can pin one of the links that answer. A short throughput probe at session start chooses the path.

## Requirements

| | Sender | Receiver |
|---|---|---|
| Hardware | Apple Silicon Mac | iMac Late 2013 or newer (Intel or Apple Silicon) |
| macOS | 14 Sonoma or newer | 10.15 Catalina or newer |
| Permissions | Screen Recording, Local Network | Local Network |

Afterscreen is an extended display only: no mirroring, audio or keyboard/mouse relay.

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

1. Connect the Macs with a Thunderbolt cable, a USB-C cable (USB networking), or an Ethernet cable (a USB-C Ethernet adapter on the Apple Silicon Mac). Wi-Fi also works.
2. Start **Afterscreen Receiver** on the iMac. Allow Local Network access.
3. Start **Afterscreen** on the Apple Silicon Mac. Allow Local Network access and Screen Recording.
4. Click the ▭ menu bar item and choose **Connect** next to the iMac. **Test** runs the quality test instead. The menu next to the iMac lists **Automatic** and each link that reaches it now (Thunderbolt, USB, Ethernet, Wi-Fi); while streaming, the same menu sits on the Method row and switches the link.

The iMac switches to a fullscreen picture of the new display. On the receiver:

- ⌥⌘I toggles the HUD
- Esc twice stops the session

While streaming, the popover has sliders for the iMac's brightness and for the volume of the sound it plays.

### Settings

Sender (**Settings…** in the popover):

| Setting | Choices |
|---|---|
| Size | Larger text, Default, More space, Most space. On a 5K iMac these look like 2048, 2560, 2880 and 3200 points wide. Applies while streaming; System Settings → Displays lists the same sizes. |
| Connect automatically | Connects to the receiver you last connected to when it appears, after sleep, and after the link drops. **Disconnect** pauses it until that receiver goes away. |
| Open at login | Starts Afterscreen at login. |
| Arrange Displays… | Opens System Settings for arrangement, mirroring and the main display. |
| Sound | Plays this Mac's sound on the iMac (on by default). The Mac stays silent meanwhile; asks once for System Audio Recording permission; about 1.5 Mbps. |
| Menu bar | The icon only (default), or also the frame rate and throughput at a fixed width. |
| Language | System (Korean when it comes first, else English), English or Korean. |

Receiver (**Settings…** in its menu):

| Setting | Choices |
|---|---|
| Open at login | Starts the receiver at login (a LaunchAgent, so it works on macOS 10.15). |
| Language | System, English or Korean. |
| Accept connections over | Any network, or cables only (Wi-Fi refused). |
| When the sender disconnects | Show this Mac's desktop, or turn the display off. A stop from the receiver always shows the desktop. |

While a stream is shown, the receiver keeps its display awake.

### Quality test

**Test** streams generated full-motion frames (every pixel changes every frame) through the real pipeline at four sizes: 0.375, 0.5, 0.75 and 1 of the panel, which on a 5K iMac means 1080p, 1440p, 4K and 5K. The iMac shows the pattern with its HUD. The popover then shows the largest size that held 55 fps or more, and the frame rate and throughput at each size. It needs no Screen Recording permission.

## Telemetry

The sender's menu bar shows the link glyph, sent frame rate and throughput, for example `▭ ϟ 60fps · 2.4G`. The popover lists:

| Field | Meaning |
|---|---|
| Method | Link type and local interface (ϟ Thunderbolt, ⌁ USB, ⇄ Ethernet, ≋ Wi-Fi, ↺ same Mac) |
| MTU | Link MTU; 9000 is recommended on Thunderbolt and USB |
| Cable quality | 0–100. Starts at 100, minus up to 40 for TCP retransmits, up to 30 for jitter, up to 30 for probe capacity below what the stream needs. |
| Throughput | Bytes sent per second, with a trend line |
| Latency (RTT) | Kernel smoothed TCP round trip on the stream connection |
| Jitter | Kernel TCP round-trip variance |
| Capacity (probe) | Throughput measured at session start |
| Retransmits | TCP retransmitted packets as a share of packets sent |
| Capture → sent → shown | Frames per second captured, sent and displayed by the receiver |
| Dropped / min | Captured frames replaced by a newer one before they could be sent |
| Path | Stream resolution of the tile picture |
| Motion | Hybrid path only: video codec, layer size and bitrate |
| Changed tiles | Share of tiles resent over the last second |
| Compression | Raw BC7 bytes ÷ bytes sent; 1.0× when the link carries frames uncompressed |
| Encode | GPU tile encode time; on the hybrid path, capture to send including the video encoder |
| CPU · RAM · GPU | This app's own use, on each side |
| Upload · decompress | Receiver texture upload and LZ4 time per frame |
| Hardware | Receiver model, panel, GPU, macOS and decoders |

## Performance

A 2017 5K iMac (iMac18,3, macOS 13.7) receiving from an Apple M5 Pro MacBook Pro, with a full-screen moving picture:

| Link (measured capacity) | Path | Frame rate | Throughput | MacBook CPU | iMac CPU |
|---|---|---|---|---|---|
| USB-C cable, USB networking (3.8 Gbps) | Tiles | 60 fps | 3.2 Gbps | 17% | 32% |
| Gigabit Ethernet (0.94 Gbps) | Hybrid, 4K HEVC layer | 60 fps | 0.41 Gbps | 27% | 11% |
| Office Wi-Fi (about 70 Mbps sustained) | Hybrid, 1440p HEVC layer | 15–52 fps, varies with the Wi-Fi | 0.07 Gbps | 8–23% | 3–7% |

A 640×440 video window ran at 60 fps on all three. See [docs/Performance.md](docs/Performance.md) for the method, the bench and before/after numbers.

## Status

Verified with automated tests, with both apps on one Mac, and on a 2017 5K iMac over USB networking, Gigabit Ethernet and Wi-Fi (see [docs/Testing.md](docs/Testing.md)). Not yet verified on macOS 10.15, on Thunderbolt 2 iMacs, or over a Thunderbolt Bridge link.

## License

MIT. See [LICENSE](LICENSE).
