# Afterscreen

Turn an iMac into an extended or mirrored display for an Apple Silicon Mac, at the iMac's native resolution: up to 5120 × 2880 at 60 fps. Connect the two Macs with a Thunderbolt cable, a USB-C cable, an Ethernet cable or plain Wi-Fi. Afterscreen is two menu bar apps, one on each Mac, built only on Apple frameworks: no capture cards, no drivers, no third-party libraries.

- **5K at 60 fps** over Thunderbolt Bridge or USB networking, with no video codec on the path: the picture goes out as GPU texture blocks that the iMac's GPU draws directly.
- **Slower links keep text sharp.** Still content stays lossless at native resolution; only the parts that move go out as HEVC or H.264 video.
- **The Mac's sound plays on the iMac's speakers** at the Mac's own volume, and the iMac's brightness follows the Mac's or is set on its own.
- **Picture quality tools**: gradient smoothing for 8-bit banding, a 10-bit output, bicubic scaling for reduced streams.
- **A quality test** that measures the highest resolution and frame rate your link sustains.
- **English and Korean** interface.

## Supported Macs

### Sender

| | |
|---|---|
| Mac | Any Apple Silicon Mac |
| macOS | 14 Sonoma or newer; sound on the iMac needs 14.2 |
| Permissions | Screen Recording, Local Network, System Audio Recording (for sound) |

### Receiver

Any iMac that runs macOS 10.15 Catalina or newer: Intel iMacs from Late 2013 on, and Apple Silicon iMacs. The receiver is one universal app (x86_64 for macOS 10.15+, arm64 for macOS 11+). It needs no video decoder for the cable links, because every Mac GPU in this range samples BC7 texture blocks in hardware.

| iMac | Model IDs | Panel | Cable links to an Apple Silicon Mac | Video for slow links | Status |
|---|---|---|---|---|---|
| 21.5" and 27", Late 2013; 21.5", Mid 2014 | iMac14,1–14,4 | 1920 × 1080, 2560 × 1440 | Thunderbolt 2 (with Apple's Thunderbolt 3 to Thunderbolt 2 adapter), Ethernet | H.264 | Expected |
| 27" 5K, Late 2014 and Mid 2015 | iMac15,1 | 5120 × 2880 | Thunderbolt 2 (adapter), Ethernet | H.264 | Expected |
| 21.5", Late 2015 (including 4K) | iMac16,1, iMac16,2 | 1920 × 1080, 4096 × 2304 | Thunderbolt 2 (adapter), Ethernet | H.264 | Expected |
| 27" 5K, Late 2015 | iMac17,1 | 5120 × 2880 | Thunderbolt 2 (adapter), Ethernet | HEVC | Expected |
| 21.5" and 27", 2017–2020 | iMac18,1–20,2 | 1920 × 1080, 4096 × 2304, 5120 × 2880 | Thunderbolt 3, USB-C, Ethernet | HEVC 10-bit | **Verified on iMac18,3** (27" 5K, 2017) |
| iMac Pro, 2017 | iMacPro1,1 | 5120 × 2880 | Thunderbolt 3, USB-C, Ethernet | Detected at run time | Expected |
| 24", Apple Silicon: M1 (2021), M3, M4 | iMac21,1, iMac21,2 and later | 4480 × 2520 | Thunderbolt / USB 4, USB-C, Ethernet where fitted | HEVC 10-bit | Expected |

The receiver detects its own hardware decoders at run time, so the "Video for slow links" column is what these models usually report. Wi-Fi works with every model. "Expected" means the model meets the requirements but has not been tested yet; see [Status](#status).

## How it works

The sender creates a virtual display the size of the iMac's panel, captures it with ScreenCaptureKit and streams it over TCP. In mirror mode it captures the Mac's main display instead, at the pixels that display draws. The receiver shows the stream full screen above the iMac's menu bar and Dock, letterboxed when its shape differs from the panel. A short throughput probe at the start of each session picks one of two picture paths:

| Link | Picture path |
|---|---|
| Wired, fast enough for the panel (2.5 Gbps for 5K at 60 Hz, scaled by pixels and refresh): Thunderbolt Bridge, USB networking, fast Ethernet | **Tiles.** Changed regions are encoded on the GPU into BC7 texture blocks and sent as 64 × 64 tiles. The iMac copies the blocks straight into a BC7 texture and draws it. There is no decoder, so there is no codec latency, and the picture is lossy only within each 4 × 4 block. |
| Slower: Gigabit Ethernet, Wi-Fi | **Hybrid.** Still tiles go out as BC7, as above. Tiles that keep moving switch to a video layer (VideoToolbox HEVC, 10-bit where the iMac decodes it, otherwise H.264) and return to lossless BC7 once they settle. The iMac draws video in the moving tiles and the BC7 picture everywhere else. |

The receiver announces itself over Bonjour (`_afterscreen._tcp`). On connect, the sender looks for the receiver on each of its network interfaces and prefers Thunderbolt, then USB, Ethernet and Wi-Fi.

## Features

**Display**
- Extend or mirror, chosen in the menu. Mirroring shows the Mac's main display the way macOS, AirPlay and Sidecar do: the Mac keeps its resolution, and the iMac shows the picture centred at its own shape with black bars around it. The stream carries the main display's own pixels, never upscaled before sending. Over Wi-Fi still areas stay 1:1 and only moving areas go at four fifths. Optimize for iMac turns the mirror the other way, as macOS's own "Optimize for": the desktop takes the iMac's shape and resolution and fills it edge to edge, while the Mac's panel shows it with bars; the Mac returns to its own resolution when the session ends. Changing the Mac's resolution or main display starts a new session at the new size.
- Extended desktop at the iMac's native resolution, with four "looks like" sizes (Larger text, Default, More space, Most space) that also appear in System Settings → Displays. Changes apply while streaming.
- Transfer resolution: automatic, panel resolution, or four fifths. Automatic sends the panel's resolution over cables and four fifths over Wi-Fi (5120 × 2880 or 4096 × 2304 on a 5K iMac). At four fifths the desktop switches to exactly half the stream's size, so the Mac draws the very pixels it sends; the size is worked out from the connected iMac's own panel.

**Links**
- Thunderbolt Bridge, USB networking (a Mac-to-Mac USB-C cable), Ethernet (a direct cable or a shared switch) and Wi-Fi.
- Automatic link choice, or pin one in the menu. The menu lists only links that reach the iMac right now; a pinned link that stops answering stays listed as "not reachable now" while the fastest link takes over.
- A hint when a Thunderbolt cable has come up as USB, and a hint to raise the MTU to 9000 on Thunderbolt and USB.

**Picture quality**
- Smooth gradients (off, low, medium, high): browsers often draw dark gradients in 8-bit steps; the iMac fills the steps in on its GPU and shows the in-between values on its 10-bit panel. Edges and text stay exact.
- Bicubic (Catmull-Rom) scaling on the iMac whenever the stream or the video layer is smaller than the panel.
- A 10-bit output on the iMac, and HEVC Main10 for the video layer where the iMac supports it.

**Sound and controls**
- The Mac's sound plays on the iMac's speakers (the Mac stays silent meanwhile), with a switch at the top of the menu. The iMac's volume and mute follow the Mac's volume keys and menu bar, and go back to the iMac's own level when the sound stops.
- The iMac's brightness follows the Mac's built-in display: brightness keys, Control Center and auto-brightness. The two panels are matched in nits, not by slider position, from peaks each Mac reports: the MacBook's brightness controller, and the iMac's own luminance measured once at launch. It stays where it is after a disconnect; a Mac without a built-in display, or with its lid closed, leaves the iMac's own. The menu has a slider for the MacBook's brightness, which the iMac follows. With the iMac as the main screen, turn off following: a second slider sets the iMac on its own, so the MacBook can be dimmed. It starts at the iMac's current level, and the setting holds across connections.
- The pointer travels on a connection of its own and never waits behind frames.
- Disconnecting, from either Mac or by quitting, plays the power-off over the live picture and sound; the sound comes back to the Mac as the iMac's screen turns black.

**Everyday use**
- Connect automatically to the last receiver when it appears, after sleep and after the link drops.
- Open at login, on both Macs.
- Pairing on shared networks: over Ethernet and Wi-Fi a receiver takes only Macs paired with it, so an office full of receivers stays each person's own. The first connection shows a 6-digit code on the iMac's screen to type on the Mac; after that both sides prove a key kept in the keychain, the Mac checking the iMac as well. Thunderbolt and USB cables connect without pairing. A wrong code shakes the boxes and can be typed again; five lock pairing for ten minutes, each later lock doubling up to a day.
- The receiver can refuse Wi-Fi connections, and can turn its display off when the sender disconnects.
- A live telemetry menu: link, throughput, measured link speed, latency, jitter, retransmits, link quality, frame rates, resolution, how moving areas are sent, CPU, memory and GPU on both Macs.
- An optional frame rate and throughput readout in the menu bar, at a fixed width so the menu does not shift.

## Optimization strategies

**No codec on fast links.** The sender's GPU encodes BC7 (mode 6) blocks; the receiver uploads them into a BC7 texture as they arrive. Decoding is the GPU's texture sampler, so on cable links an iMac without an HEVC decoder is not held back by one.

**Send only what changed.** ScreenCaptureKit reports the changed regions of each frame. Only tiles under them are encoded, then compared block by block on the GPU against the last picture sent; tiles that differ go out as runs. A rolling refresh re-checks 1/64 of the screen per frame.

**Motion follows the link.** A tile that changes again within 50 ms counts as moving. On the tile path, moving tiles stay BC7 while they fit half the measured link at the iMac's refresh rate (on Thunderbolt, 85% of a 5K screen can move at full quality); past that they go out as BC1 at half the size. Once a tile has been still for 100 ms, its lossless BC7 version follows. LZ4 runs only when a frame would not fit the link otherwise.

**Video only where it moves.** On the hybrid path a per-tile mask tells the iMac which tiles show video. The video layer is 4K, 1440p or 1080p, the largest the link's bitrate fills at 0.15 bit per pixel per frame that this Mac's encoder also keeps up with: on the first hybrid connection it encodes half a second of moving test frames at that size (about 0.35 s, once per launch) and steps down if it falls short. The iMac maps the layer straight onto the panel. The VideoToolbox encoder is pipelined, frames leave in order, and there are no periodic keyframes: TCP loses nothing, and the iMac asks for a keyframe only if decoding fails. Every encoder input is tagged BT.709, so video tiles match the BC7 tiles around them within one level.

**Never queue stale frames.** At most two frames are on the wire or in the encoder. A newer capture replaces one that has not been sent yet, so after a stall the iMac jumps to the newest picture instead of replaying old ones. The receiver uploads frames that have newer ones queued behind them without drawing them, so its display refresh never limits how fast frames are taken in.

**Pick the fastest path to the iMac.** The receiver's Bonjour name is looked up on each interface separately, because a lookup across all interfaces stops at the first answer, often Wi-Fi. Link-local addresses are used only on the interface that answered them. Socket buffers (4 MiB) are sized before connecting, and Nagle's algorithm is off.

**Capture only the precision that exists.** Virtual displays composite in 8 bits, so the capture is 8-bit BGRA: a 10-bit capture added no levels and cost the compositor time. Reduced streams draw the desktop at the stream's own pixels, so nothing is scaled before sending and the iMac scales once.

**Cheap work on the iMac.** Gradient smoothing is kept in a 10-bit texture and recomputed only for tiles that changed and their neighbours within reach: a still screen costs one texture sample per pixel (iMac Radeon Pro 570, 5K, medium: 10–14% GPU instead of 63% when every pixel was recomputed each frame). Bicubic scaling runs only when the picture is scaled up.

**Sound without crackle.** A Core Audio process tap captures the Mac's output and mutes it locally. 16-bit PCM in packets of about 10 ms travels on the pointer's connection, about 1.5 Mbps at 48 kHz stereo. The iMac plays it through a jitter buffer that starts at 30 ms, grows by half after each gap up to 150 ms for jittery Wi-Fi, shrinks again after 30 s without one, and corrects clock drift by resampling 0.2% faster or slower instead of dropping samples.

## Performance

Measured on a 2017 5K iMac (iMac18,3, Radeon Pro 570, macOS 13.7.8) receiving from an Apple M5 Pro MacBook Pro:

| Link (measured capacity) | Path | Full-screen motion | Notes |
|---|---|---|---|
| Thunderbolt Bridge (11–13 Gbps) | Tiles | 5K at 60 fps | Quality test: 4K stage at 60 fps with BC7 motion (3.98 Gbps); 5K stage at 60 fps with BC1 motion (3.54 Gbps) |
| USB-C cable, USB networking (3.8 Gbps) | Tiles | 5K at 60 fps | 3.2 Gbps; MacBook CPU 17%, iMac CPU 32% |
| Gigabit Ethernet, direct cable (0.94 Gbps) | Hybrid, 4K HEVC layer | 5K at 60 fps | 0.41 Gbps; MacBook CPU 27%, iMac CPU 11% |
| Office Wi-Fi (about 70 Mbps sustained) | Hybrid, 1440p HEVC layer | 15–52 fps, varies with the Wi-Fi | A video window held 60 fps |
| Home Wi-Fi (0.16–0.22 Gbps probe) | Hybrid at 4096 × 2304, 1440p layer | 60 fps in the quality test | Wi-Fi latency spikes of 300–600 ms show as brief pauses |

Video content plays at its own frame rate: a 24 fps video shows 24 new frames per second. See [docs/Performance.md](docs/Performance.md) for the method, the bench and before/after numbers.

## Build

Requires Xcode with the macOS SDK on an Apple Silicon Mac.

```sh
zsh scripts/build_apps.sh
```

This produces:

- `build/Afterscreen.app`: the sender (arm64, macOS 14+)
- `build/Afterscreen Receiver.app`: the receiver (universal, macOS 10.15+)

The script draws the app icon from `scripts/icons.swift`, strips symbols from both executables and signs them with `AFTERSCREEN_SIGN_IDENTITY` when set, else with the first Apple Development identity in the keychain, else ad hoc. An ad hoc signature changes with every build, so macOS asks for the privacy permissions again each time.

The receiver is compiled with `swiftc` directly, because current SwiftPM refuses deployment targets below macOS 12. The Swift packages are used for the tests:

```sh
swift test --package-path Core
swift test --package-path Sender
swift test --package-path Receiver
```

## Usage

1. Connect the Macs with a Thunderbolt cable, a USB-C cable or an Ethernet cable (a USB-C Ethernet adapter on the Apple Silicon Mac), or put both on the same Wi-Fi.
2. Start **Afterscreen Receiver** on the iMac and allow Local Network access.
3. Start **Afterscreen** on the Apple Silicon Mac and allow Local Network access and Screen Recording.
4. Click the ▭ menu bar item and choose **Connect** next to the iMac, or **Test** to run the quality test.

On the iMac, ⌥⌘I shows a heads-up display and pressing Esc twice stops the session.

For Thunderbolt Bridge, jumbo frames cut the packets per second each Mac handles about sixfold. Set them on both Macs, then reconnect:

```sh
sudo networksetup -setMTU "Thunderbolt Bridge" 9000
```

### Settings

Sender (**Settings** in the menu opens them in place; **Back** returns):

| Setting | Choices |
|---|---|
| Use as | Extend or Mirror; mirroring fits this Mac or the receiver, both named. |
| Size | Larger text, Default, More space, Most space. On a 5K iMac these look like 2048, 2560, 2880 and 3200 points wide. |
| Transfer resolution | Automatic (default), panel resolution, or four fifths, as described under [Features](#features). Takes effect by reconnecting. |
| Connect automatically | Connects to the receiver you last connected to. **Disconnect** pauses it until that receiver goes away. |
| Open at login | Starts Afterscreen at login. |
| Arrange Displays… | Opens System Settings for arrangement and the main display. |
| Menu bar | The icon only (default), or also the frame rate and throughput. |
| Paired receivers | Each with Remove. |
| Language | System, English or Korean. |

In the menu while streaming: sound on the receiver with this Mac's volume slider, brightness sliders for this Mac and, when not following, the receiver, the link, Use as (Extend or Mirror), and Smooth gradients (medium by default).

Receiver (**Settings…** in its menu):

| Setting | Choices |
|---|---|
| Open at login | Starts the receiver at login (a LaunchAgent, so it works on macOS 10.15). |
| Language | System, English or Korean. |
| Accept connections over | Any network, or cables only (Wi-Fi refused). |
| When the sender disconnects | Show this Mac's desktop, or turn the display off. A stop on the receiver always shows the desktop. |

### Quality test

**Test** streams generated full-motion frames, where every pixel changes every frame, through the real pipeline at 0.375, 0.5, 0.75 and 1 of the panel (1080p, 1440p, 4K and 5K on a 5K iMac). The iMac shows the pattern with its heads-up display, and the menu then shows the largest size that held 55 fps or more, with the frame rate and throughput at each size. It needs no Screen Recording permission.

### Menu fields

| Field | Meaning |
|---|---|
| Link | Link type and local interface: ϟ Thunderbolt, ⌁ USB, ⇄ Ethernet, ≋ Wi-Fi |
| Throughput | Data sent to the iMac per second, with a trend line |
| Measured link speed | Data actually sent in 0.3 s at the start of the session; not the cable's rated speed |
| Latency, Jitter | The kernel's TCP round-trip time on the stream connection, and how much it varies |
| Retransmits | Packets sent again after a loss |
| Link quality | 100, minus penalties for retransmits, jitter and a link slower than the stream needs |
| MTU | Packet size; 9000 is recommended on Thunderbolt and USB |
| Use as | Extend: the iMac is a display of its own. Mirror: it shows the Mac's main display |
| Optimize for | While mirroring. This Mac: it keeps its resolution. iMac: the desktop takes the iMac's resolution |
| Frames: captured · sent · shown | Frames per second the Mac drew, sent, and the iMac showed |
| Dropped / min | Frames replaced by a newer one before they could be sent |
| Resolution | Size of the stream |
| Moving areas | Tile path: BC7, or BC1 and how many tiles. Hybrid path: video codec, layer size and bitrate |
| Changed area | Share of the screen sent again in the last second |
| Compression | Data before and after LZ4; 1.0× when the link carries frames uncompressed |
| Encode time | From capture to send, per frame |
| CPU · RAM · GPU | Afterscreen's own use, on each Mac |
| iMac upload · decompress | The iMac's texture upload and LZ4 time per frame |
| iMac hardware | Model, panel, GPU, macOS and hardware decoders |

## Limitations

- Extended display only: no mirroring, and the iMac's keyboard and mouse are not relayed to the Mac.
- Wi-Fi depends on the network. Latency spikes in the Wi-Fi itself show as brief pauses; a cable avoids them.
- Full-screen video in Chrome on a virtual display alternates between about 45 and 60 fps; Safari holds 60 fps. This happens before Afterscreen receives the frames and also affects other virtual display apps.

## Status

Verified with automated tests (core, sender and receiver), with both apps on one Mac, and on a 2017 5K iMac over Thunderbolt Bridge, USB networking, Gigabit Ethernet and Wi-Fi. Not yet verified: macOS 10.15 receivers, Thunderbolt 2 iMacs, H.264-only receivers, and the Apple Silicon iMacs. See [docs/Testing.md](docs/Testing.md), including how to save what the receiver draws for debugging.

Design notes: [docs/specs](docs/specs).

## License

MIT. See [LICENSE](LICENSE).

iMac, Mac and macOS are trademarks of Apple Inc. Thunderbolt is a trademark of Intel Corporation. Afterscreen is not affiliated with or endorsed by Apple.
