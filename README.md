# Afterscreen

Turn an iMac into an extended or mirrored display for an Apple Silicon Mac, at the iMac's native resolution: up to 5120 × 2880 at 60 fps. Connect the two Macs with a Thunderbolt cable, a USB-C cable, an Ethernet cable or plain Wi-Fi. Afterscreen is two menu bar apps, one on each Mac, built only on Apple frameworks: no capture cards, no drivers, no third-party libraries.

- **5K at 60 fps** over Thunderbolt Bridge or USB networking, with no video codec on the path: the picture goes out as GPU texture blocks that the iMac's GPU draws directly.
- **Slower links keep text sharp.** Still content stays lossless at native resolution; only the parts that move go out as HEVC or H.264 video.
- **The Mac's sound plays on the iMac's speakers** at the Mac's own volume, and the iMac's brightness follows the Mac's or is set on its own.
- **Picture quality tools**: gradient smoothing for 8-bit banding, a 10-bit output, bicubic scaling for reduced streams.
- **A quality test** that measures the highest resolution and frame rate your link sustains, and the frame rate of typical use.
- **English and Korean** interface.

## Supported Macs

### Sender

| | |
|---|---|
| Mac | Any Apple Silicon Mac |
| macOS | 14 Sonoma or newer; sound on the iMac needs 14.2 |
| Permissions | Screen Recording, Local Network, System Audio Recording (for sound) |

### Receiver

Any Mac that runs macOS 10.15 Catalina or newer, Intel or Apple Silicon: an iMac or MacBook on its own panel, or a Mac mini, Mac Pro or closed MacBook on a monitor attached to it. The rest of this README says "the iMac" for whichever Mac receives. The receiver is one universal app (x86_64 for macOS 10.15+, arm64 for macOS 11+). It needs no video decoder for the cable links, because every Mac GPU in this range samples BC7 texture blocks in hardware. It draws with the GPU that drives its screen. A 15- or 16-inch MacBook Pro with two GPUs asks macOS for the discrete GPU only while it streams on its own panel, and draws with the integrated GPU between sessions, so an idle receiver does not hold the discrete GPU. The sender shows each receiver by its model name, from a table of the Macs in this range; a newer Mac shows its model identifier.

| iMac | Model IDs | Panel | Cable links to an Apple Silicon Mac | Video for slow links | Status |
|---|---|---|---|---|---|
| 21.5" and 27", Late 2012; 21.5", Early 2013 | iMac13,1–13,3 | 1920 × 1080, 2560 × 1440 | Thunderbolt 1 (with Apple's Thunderbolt 3 to Thunderbolt 2 adapter), Ethernet | H.264 | Expected |
| 21.5" and 27", Late 2013; 21.5", Mid 2014 | iMac14,1–14,4 | 1920 × 1080, 2560 × 1440 | Thunderbolt 1 (adapter), Ethernet | H.264 | Expected |
| 27" 5K, Late 2014 and Mid 2015 | iMac15,1 | 5120 × 2880 | Thunderbolt 2 (adapter), Ethernet | H.264 | Expected |
| 21.5", Late 2015 (including 4K) | iMac16,1, iMac16,2 | 1920 × 1080, 4096 × 2304 | Thunderbolt 2 (adapter), Ethernet | H.264 | Expected |
| 27" 5K, Late 2015 | iMac17,1 | 5120 × 2880 | Thunderbolt 2 (adapter), Ethernet | HEVC | Expected |
| 21.5" and 27", 2017–2020 | iMac18,1–20,2 | 1920 × 1080, 4096 × 2304, 5120 × 2880 | Thunderbolt 3, USB-C, Ethernet | HEVC 10-bit | **Verified on iMac18,3** (27" 5K, 2017) |
| iMac Pro, 2017 | iMacPro1,1 | 5120 × 2880 | Thunderbolt 3, USB-C, Ethernet | Detected at run time | Expected |
| 24", Apple Silicon: M1 (2021), M3, M4 | iMac21,1, iMac21,2 and later | 4480 × 2520 | Thunderbolt / USB 4, USB-C, Ethernet where fitted | HEVC 10-bit | Expected |

| Other Intel Mac | Model IDs | Screen | Cable links to an Apple Silicon Mac | Video for slow links | Status |
|---|---|---|---|---|---|
| MacBook Air, Mid 2012–2017 | MacBookAir5,1–7,2 | 1366 × 768, 1440 × 900 | Thunderbolt 1 or 2 (adapter) | H.264 | Expected |
| MacBook Air, 2018–2020 | MacBookAir8,1–9,1 | 2560 × 1600 | Thunderbolt 3, USB-C | HEVC 10-bit | Expected |
| MacBook 12", 2015–2017 | MacBook8,1–10,1 | 2304 × 1440 | USB-C (no Thunderbolt) | H.264 (2015), HEVC (2016), HEVC 10-bit (2017) | Expected |
| MacBook Pro, Mid 2012–2015 | MacBookPro9,1–12,1 | 1280 × 800 to 2880 × 1800 | Thunderbolt 1 or 2 (adapter); Ethernet on the Mid 2012 models without Retina | H.264 | Expected |
| MacBook Pro, 2016–2020 | MacBookPro13,1–16,4 | 2560 × 1600, 2880 × 1800, 3072 × 1920 | Thunderbolt 3, USB-C | HEVC (2016), HEVC 10-bit (2017–2020) | Expected |
| Mac mini, Late 2012 and Late 2014 | Macmini6,1, Macmini6,2, Macmini7,1 | Its monitor | Thunderbolt 1 or 2 (adapter), Ethernet | H.264 | Expected |
| Mac mini, 2018 | Macmini8,1 | Its monitor | Thunderbolt 3, USB-C, Ethernet | HEVC 10-bit | Expected |
| Mac Pro, Late 2013 | MacPro6,1 | Its monitor | Thunderbolt 2 (adapter), Ethernet | Detected at run time | Expected |
| Mac Pro, 2019 | MacPro7,1 | Its monitor | Thunderbolt 3, USB-C, Ethernet | Detected at run time | Expected |

MacBooks without an Ethernet port reach Ethernet through an adapter. A monitor keeps its own brightness unless macOS itself can set it, as on Apple's displays.

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
- Extend or mirror, chosen in the menu. Mirroring shows the Mac's main display the way macOS, AirPlay and Sidecar do: the Mac keeps its resolution, and the iMac shows the picture centred at its own shape with black bars around it. The stream carries the main display's own pixels, never upscaled before sending. When the stream is reduced, a main display within four fifths of the panel keeps its still areas 1:1, and only moving areas go at four fifths. Optimize for iMac turns the mirror the other way, as macOS's own "Optimize for": the desktop takes the iMac's shape and resolution and fills it edge to edge, while the Mac's panel shows it with bars; the Mac returns to its own resolution when the session ends. Changing the Mac's resolution or main display starts a new session at the new size.
- Extended desktop at the iMac's native resolution, with four "looks like" sizes (Larger text, Default, More space, Most space) that also appear in System Settings → Displays. Changes apply while streaming.
- The receiver's screen is picked in its settings. Automatic takes the Mac's own panel (iMac, MacBook), else the screen with the menu bar; a chosen monitor that is unplugged falls back to automatic, and a session whose screen goes away ends and reconnects. The sender learns that screen's panel, size and refresh at each connection.
- On a MacBook with a camera notch the stream fills the panel below it, pixel for pixel (14-inch: 3024 × 1896), in either presentation. While streaming, a scaled resolution on the receiver's screen ("More Space") switches to the panel's own and returns afterwards, so the stream is not resampled twice; windows on that Mac may move when it switches back, and a setting turns this off.
- Up to 60 fps. On Thunderbolt, an experimental setting sends 120 fps to a receiver at 120 Hz or more (MacBook Pro) when the measured link carries lossless tiles at 120 fps and this Mac's tile encoder takes under half a frame: it encodes moving test frames at the panel's size while connecting (M5 Pro: 1.7 ms at 3024 × 1900).
- Transfer resolution: automatic, panel resolution, or four fifths. Automatic decides by the measured link rate, whatever the link kind: the panel's resolution when the link settles a full screen of lossless tiles within a quarter second, four fifths below that. On a 5K iMac that is 5120 × 2880 from about 0.47 Gbps (gigabit Ethernet, fast Wi-Fi) and 4096 × 2304 under it. A mirrored display is measured at its own size. Near the line the last choice for that iMac holds until the rate moves 20%, so the desktop does not change size from one connection to the next. At four fifths the desktop switches to exactly half the stream's size, so the Mac draws the very pixels it sends; the size is worked out from the connected iMac's own panel.

**Links**
- Thunderbolt Bridge, USB networking (a Mac-to-Mac USB-C cable), Ethernet (a direct cable or a shared switch) and Wi-Fi.
- Automatic link choice, or pin one in the menu. The menu lists only links that reach the iMac right now; a pinned link that stops answering stays listed as "not reachable now" while the fastest link takes over. On automatic, a faster link that comes up during a session, such as a cable plugged in while on Wi-Fi, takes the session over; if it fails to connect, it is tried once more 10 seconds later. Choosing a link in the menu moves the session the same way. With a receiver of this version the stream moves between two frames without a reconnect: the iMac's window, the Mac's windows on the extended display and the sound carry on. The new link is measured first, and the path, video layer and bitrate follow it; the transfer resolution stays until the next connection. The new link proves the session's pairing key, or its session token on a link that needs no pairing. An older receiver reconnects briefly instead.
- When the session's link drops, such as an unplugged cable, the stream continues over the next link that answers, or over the same cable once it is back, and the Mac's windows stay where they are. Meanwhile the iMac holds its picture in grey, each tile breathing slightly, with a "Reconnecting" notice; when the stream returns, colour comes back from the centre outward and every tile is sent once more. If no link answers within 8 seconds, black tiles close in from the edges and the session ends. Reduce Motion keeps the grey picture still.
- A hint when a Thunderbolt cable has come up as USB.

**Picture quality**
- Smooth gradients (off, low, medium, high): browsers often draw dark gradients in 8-bit steps; the iMac fills the steps in on its GPU and shows the in-between values on its 10-bit panel. Edges and text stay exact.
- Bicubic (Catmull-Rom) scaling on the iMac whenever the stream or the video layer is smaller than the panel.
- A 10-bit output on the iMac, and HEVC Main10 for the video layer where the iMac supports it.

**Sound and controls**
- The Mac's sound plays on the iMac's speakers (the Mac stays silent meanwhile), with a switch at the top of the menu. The iMac's volume and mute follow the Mac's volume keys and menu bar, and go back to the iMac's own level when the sound stops.
- The iMac's brightness follows the Mac's built-in display: brightness keys, Control Center and auto-brightness. The two panels are matched in nits, not by slider position, from peaks each Mac reports: the MacBook's brightness controller, and the iMac's own luminance measured once at launch. It stays where it is after a disconnect; a Mac without a built-in display, or with its lid closed, leaves the iMac's own. The menu has a slider for the MacBook's brightness, which the iMac follows. With the iMac as the main screen, turn off following: a second slider sets the iMac on its own, so the MacBook can be dimmed. It starts at the iMac's current level, and the setting holds across connections.
- The pointer travels on a connection of its own and never waits behind frames.
- Disconnecting, from either Mac or by quitting, plays the power-off over the live picture and sound; the sound comes back to the Mac as the iMac's screen turns black. Putting the Mac to sleep does the same, and sleep waits for it, up to two seconds.

**Everyday use**
- Connect automatically to the last receiver when it appears, after sleep and after the link drops. Never while the Mac's screens are off, as in a dark wake.
- On power, closing the MacBook's lid keeps streaming in closed-display mode: macOS moves its windows to the iMac as to any display, and back when the lid opens.
- Open at login, on both Macs.
- Pairing on shared networks: over Ethernet and Wi-Fi a receiver takes only Macs paired with it, so an office full of receivers stays each person's own. The first connection shows a 6-digit code on the iMac's screen to type on the Mac; after that both sides prove a key kept in the keychain, the Mac checking the iMac as well. Thunderbolt and USB cables connect without pairing. A wrong code shakes the boxes and can be typed again; five lock pairing for ten minutes, each later lock doubling up to a day.
- The receiver can refuse Wi-Fi connections, and can turn its display off when the sender disconnects.
- The sender can put the receiver to sleep or shut it down when you disconnect, quit or shut the Mac down, as a display turns off with its computer.
- A live telemetry menu: link, throughput, measured link speed, latency, jitter, retransmits, link quality, frame rates, resolution, how moving areas are sent, CPU, memory and GPU on both Macs.
- An optional frame rate and throughput readout in the menu bar, at a fixed width so the menu does not shift.

## Optimization strategies

**No codec on fast links.** The sender's GPU encodes BC7 (mode 6) blocks; the receiver uploads them into a BC7 texture as they arrive. Decoding is the GPU's texture sampler, so on cable links an iMac without an HEVC decoder is not held back by one.

**Send only what changed.** ScreenCaptureKit reports the changed regions of each frame. Only tiles under them are encoded, then compared block by block on the GPU against the last picture sent; tiles that differ go out as runs. A rolling refresh re-checks 1/64 of the screen per frame.

**Motion follows the link.** A tile that changes again within 50 ms counts as moving. On the tile path, moving tiles stay BC7 while they fit half the measured link at the iMac's refresh rate (on Thunderbolt, 85% of a 5K screen can move at full quality); past that they go out as BC1 at half the size. Once a tile has been still for 100 ms, its lossless BC7 version follows. LZ4 runs only when a frame would not fit the link otherwise.

**A shared link costs quality, not frames.** The video bitrate starts at 40% of the measured link. Once a second the sender checks its socket: when sent data waits there over 0.15 s, or the round trip stays 30 ms above its recent best, the bitrate drops by 30%, down to an eighth of the start. After three clear seconds it climbs back 10% a second. A still screen and a slow-reading receiver do not count. On Wi-Fi the streams are marked as interactive video, so this Mac sends them ahead of its own downloads. When the bitrate stays at half or less for 5 s, the iMac shows a short notice, at most once in 10 minutes, and the menu shows the lowered rate until it recovers. With a large download on the same Wi-Fi, 5K stages that had stalled at 1–2 fps held 45–58 fps in most runs; a whole-screen change during heavy congestion can still pause.

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
| Thunderbolt Bridge (11–13 Gbps) | Tiles | 5K at 60 fps | Quality test: every stage at 60 fps, 5K full motion at 6.29 Gbps, typical use at 1.99 Gbps |
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

The script draws both app icons from `scripts/icons.swift`, strips symbols from both executables and signs them with `AFTERSCREEN_SIGN_IDENTITY` when set, else with the first Apple Development identity in the keychain, else ad hoc. An ad hoc signature changes with every build, so macOS asks for the privacy permissions again each time.

The receiver is compiled with `swiftc` directly, because current SwiftPM refuses deployment targets below macOS 12. It carries the toolchain's back-deployed Swift concurrency library: code built against the current SwiftUI SDK needs it, and macOS includes it only from 12. Signed without a Team ID (ad hoc or self-signed), the receiver goes without the hardened runtime, whose library validation would refuse that copy. The Swift packages are used for the tests:

```sh
swift test --package-path Core
swift test --package-path Sender
swift test --package-path Receiver
```

## Usage

1. Connect the Macs with a Thunderbolt cable, a USB-C cable or an Ethernet cable (a USB-C Ethernet adapter on the Apple Silicon Mac), or put both on the same Wi-Fi.
2. Start **Afterscreen Receiver** on the iMac and allow Local Network access.
3. Start **Afterscreen** on the Apple Silicon Mac and allow Local Network access and Screen Recording.
4. Click the Afterscreen menu bar item, a display with ↗ in its corner (the receiver's has ↙; ▭ on macOS 10.15), and choose **Connect** next to the iMac, or **Test** to run the quality test.

On the iMac, ⌥⌘I shows a heads-up display and pressing Esc twice stops the session.

### Settings

Sender (**Settings** in the menu opens them in place; **Back** returns):

| Setting | Choices |
|---|---|
| Use as | Extend or Mirror; mirroring fits this Mac or the receiver, both named. |
| Size | Larger text, Default, More space, Most space. On a 5K iMac these look like 2048, 2560, 2880 and 3200 points wide. |
| Transfer resolution | Automatic (default), panel resolution, or four fifths, as described under [Features](#features). Takes effect by reconnecting. |
| 120 fps (experimental) | Off by default. On Thunderbolt to a receiver at 120 Hz or more, 120 fps when the encoder keeps up; the menu says which rate was chosen and why. |
| Connect automatically | Connects to the receiver you last connected to. **Disconnect** pauses it until that receiver goes away. |
| Open at login | Starts Afterscreen at login. |
| Receiver after disconnecting | Stays on (default), sleeps or shuts down when you click **Disconnect**, quit Afterscreen or shut this Mac down. A restart, log out, sleep or dropped link leaves it on. A receiver of this version or later follows it when paired or on a Thunderbolt or USB cable. Shutting down needs **Allow…** in the receiver's settings; until then the receiver sleeps. Apps there may ask to save first. |
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
| Show on | Automatic (this Mac's own panel first), or one of the connected screens. |
| Switch the screen to its 1:1 resolution while streaming | On by default: a scaled resolution blurs the stream by resampling it twice. |
| When the sender disconnects | Show this Mac's desktop, or turn the display off. A stop on the receiver always shows the desktop. The sender's sleep or shut down request comes first. |
| Shut down when the sender asks | **Allow…** asks macOS once for consent to shut this Mac down. Until then the sender's request puts it to sleep. |

### Quality test

**Test** streams a generated pattern through the real pipeline in five stages. It needs no Screen Recording permission.

- **Full motion**, at 0.375, 0.5, 0.75 and 1 of the panel (1080p, 1440p, 4K and 5K on a 5K iMac). Every tile changes every frame. The menu shows the largest size that held 55 fps or more. On the hybrid path full motion travels as video, so the menu also names the size of the video layer that carried it.
- **Typical use**, at the size a session would stream. Only a video window, a scrolling document and the frame ladder move, about a third of the screen. This is the frame rate to expect from everyday work over the link.

The iMac shows the pattern with its heads-up display, and the menu lists the frame rate and throughput of each stage. The pattern can also be read by eye. Its caption names the link, the stage and the frame number. A ladder along the top lights one cell per frame, so a skipped cell is a frame that never reached the screen. A card crosses at a constant speed with text at four sizes, a gray ramp and red-on-blue labels, so stutter, banding and lost color detail show on it. Nothing flashes, and there are no high-contrast stripes.

### Menu fields

Connection, Picture, Resources and the iMac's hardware fold at their titles. Folded, Connection keeps a chart of the last 60 seconds of throughput and latency, with the link, its picker, the changed blocks and the link quality score over it; Picture keeps its controls and the frame counts.

| Field | Meaning |
|---|---|
| Link | Link type and local interface: ϟ Thunderbolt, ⌁ USB, ⇄ Ethernet, ≋ Wi-Fi |
| Throughput | Screen data sent to the iMac per second, without sound and cursor |
| Changed blocks | 64-pixel blocks that changed per frame, last second's average, of all on screen; video areas included. A still-looking screen with blocks here has something moving, such as a spinner |
| Measured link speed | Data actually sent in 0.3 s, once when the session starts; not the cable's rated speed |
| Latency, Jitter | The kernel's TCP round-trip time on the stream connection, in whole milliseconds, and how much it varies |
| Retransmits | Packets sent again after a loss in the last second |
| Link quality | 100, minus penalties for retransmits, jitter and a link slower than the stream needs |
| Use as | Extend: the iMac is a display of its own. Mirror: it shows the Mac's main display |
| Optimize for | While mirroring. This Mac: it keeps its resolution. iMac: the desktop takes the iMac's resolution |
| Frames: captured · sent · shown | Frames per second the Mac drew, sent, and the iMac showed; shown counts redraws, so it can pass sent |
| Skipped / min | Captures skipped while the link or encoder was busy; their changes go out with the next frame |
| Transfer resolution | Size the screen is drawn and sent at; still areas arrive at it as BC7 |
| Motion sent as | Tile path: BC7, or BC1 and how many tiles. Hybrid path: video codec and the size the whole screen is scaled to |
| Video target bitrate | Hybrid path: what the video encoder aims for; lowered while the network is busy |
| Tile LZ4 ratio | Tile data before and after LZ4, video not included; 1.0× when the link has room and LZ4 is skipped |
| Show sent blocks on the iMac | For checking: changed blocks flash red, blocks sent again sharper yellow, video blue, on the same grid as the power and waiting effects. Off when Afterscreen starts again |
| Smooth gradients | Fills 8-bit steps in dark gradients on the iMac, in tile areas only |
| Frame processing | Average per frame in the last second, from processing start until queued to send, video encoding included |
| CPU · RAM · GPU | Afterscreen's own use, on each Mac; one core is 100% CPU, and GPU leaves out video encoding and decoding |
| iMac upload · decompress | The iMac's upload preparation and LZ4 time for the latest tile frame; video decoding not included |
| iMac hardware | Model, model identifier, panel, GPU, macOS and hardware video decoders |

## Limitations

- The iMac's keyboard and mouse are not relayed to the Mac.
- Wi-Fi depends on the network. Latency spikes in the Wi-Fi itself show as brief pauses; a cable avoids them.
- Full-screen video in Chrome on a virtual display alternates between about 45 and 60 fps; Safari holds 60 fps. This happens before Afterscreen receives the frames and also affects other virtual display apps.

## Status

Verified with automated tests (core, sender and receiver), with both apps on one Mac (a 14-inch MacBook Pro as the receiver, on its notched panel and on external monitors), and on a 2017 5K iMac over Thunderbolt Bridge, USB networking, Gigabit Ethernet and Wi-Fi. Not yet verified: macOS 10.15 receivers, Thunderbolt 1 and 2 Macs, H.264-only receivers, Intel MacBooks, Mac minis and Mac Pros (including a two-GPU MacBook Pro switching GPUs per session), the Apple Silicon iMacs, an M1 sender, and 120 fps across two Macs. See [docs/Testing.md](docs/Testing.md), including how to save what the receiver draws for debugging.

Design notes: [docs/specs](docs/specs).

## License

MIT. See [LICENSE](LICENSE).

iMac, Mac and macOS are trademarks of Apple Inc. Thunderbolt is a trademark of Intel Corporation. Afterscreen is not affiliated with or endorsed by Apple.
