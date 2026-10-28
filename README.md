# Afterscreen

[한국어](README.ko.md)

Use an iMac as a display for your Apple Silicon Mac, extended or mirrored, at the iMac's own resolution: up to 5120 × 2880 at 60 fps.

iMacs from late 2014 on have no Target Display Mode. Afterscreen gives them, and older iMacs too, a second life as a display. It is two menu bar apps, one on each Mac, connected by a cable or Wi-Fi. There is no capture card, no driver and no third-party library.

## Why Afterscreen

- **Sharp text at full resolution.** On a fast cable the screen goes out as GPU texture blocks, not as video, and the iMac's GPU draws them directly. There is no video decoder on the path, so there is no codec delay.
- **Any connection.** Thunderbolt, a USB-C cable, Ethernet or Wi-Fi. On slower links only the moving parts of the screen go out as video. Still parts stay at full resolution.
- **The fastest link, kept up to date.** Afterscreen picks the fastest link to the iMac. Plug in a cable mid-session and the stream moves to it between two frames, with no reconnect. If a link drops, the session continues over another one, and your windows stay where they are.
- **Old Macs welcome.** The receiver runs on macOS 10.15 Catalina or newer, Intel or Apple Silicon. Besides iMacs, a MacBook, a Mac mini or a Mac Pro with a monitor can also receive.
- **It feels like one display.** The Mac's sound plays on the iMac's speakers at the Mac's volume. The iMac's brightness follows the Mac's built-in display, matched in nits.

## Features

- **Display:** Extend or mirror. Four sizes, from Larger text to Most space. On a MacBook receiver, the stream fills the screen below the camera notch.
- **Picture:**
  - Gradient smoothing for 8-bit banding.
  - 10-bit output, and bicubic scaling when the stream is smaller than the panel.
  - Resolution and video bitrate follow the measured link.
- **Connection:**
  - Connects automatically to the last receiver, including after sleep.
  - On Ethernet and Wi-Fi, a receiver takes only Macs paired with it by a 6-digit code. Thunderbolt and USB cables connect without pairing.
- **Power:**
  - Disconnecting plays a power-off effect on the iMac.
  - The sender can put the receiver to sleep or shut it down when you disconnect.
  - Closing a MacBook's lid on power keeps streaming.
- **Receiver settings from the sender:**
  - While connected, the sender's menu changes how and where the iMac shows the stream, its effect and what it shows with no sender. It also shows or hides the iMac's HUD.
  - Which connections the iMac accepts, its pairings and its permission to shut down are set on the iMac only.
- **Tools:**
  - A quality test that measures what your link sustains.
  - A live menu of link, throughput, latency, frame rates and resource use on both Macs.
- **Languages:** English and Korean. The iMac follows the language chosen on the sender, the system language by default.

## Performance

Measured with a 2017 27-inch 5K iMac (iMac18,3) receiving from an M5 Pro MacBook Pro:

| Link | Full-screen motion |
|---|---|
| Thunderbolt Bridge | 5K at 60 fps |
| USB-C cable (USB networking) | 5K at 60 fps |
| Gigabit Ethernet, direct cable | 5K at 60 fps, motion as 4K HEVC video |
| Wi-Fi | 15–60 fps, depending on the network |

## Requirements

**Sender:** an Apple Silicon Mac with macOS 14 Sonoma or newer. Sound on the iMac needs macOS 14.2. The app asks for Screen Recording, Local Network and, for sound, System Audio Recording.

**Receiver:** any Mac with macOS 10.15 Catalina or newer. All of them can use Wi-Fi. Cable links:

| Receiver | Cable links |
|---|---|
| iMac 2017–2020, iMac Pro | Thunderbolt 3, USB-C, Ethernet |
| iMac 2012–2015 | Thunderbolt 1 or 2 through Apple's Thunderbolt 3 to Thunderbolt 2 adapter, Ethernet |
| Apple Silicon iMac | Thunderbolt, USB-C, Ethernet where fitted |
| MacBook, Mac mini, Mac Pro | Thunderbolt or USB-C (Thunderbolt 1 and 2 through the adapter), Ethernet |

Tested on a 2017 27-inch 5K iMac over all four links. Other models meet the requirements but have not been tested yet.

## Getting started

1. From [Releases](https://github.com/lakystars/afterscreen/releases), download `Afterscreen-<version>.zip` (the sender) and `Afterscreen-Receiver-<version>.zip` (the receiver).
2. Unzip them. Move **Afterscreen** to Applications on the Apple Silicon Mac, and **Afterscreen Receiver** to Applications on the iMac.
3. Connect the Macs with a Thunderbolt, USB-C or Ethernet cable, or put them on the same Wi-Fi.
4. On the iMac, open **Afterscreen Receiver** and allow Local Network access when asked.
5. On the Apple Silicon Mac, open **Afterscreen** and allow Local Network access and Screen Recording.
6. Click the Afterscreen menu bar icon and choose **Connect** next to the iMac.

On the iMac, pressing Esc twice stops the session, and ⌥⌘I shows a heads-up display.

### First launch

The release builds are not notarized by Apple, so macOS warns the first time you open them.

- **macOS 15 or newer:** open the app once, then click **Open Anyway** in System Settings → Privacy & Security.
- **macOS 14 or older:** Control-click the app, choose **Open**, then click **Open** again.

The builds are signed ad hoc, so each new version asks for Screen Recording and Local Network access again.

To build the apps yourself, see [Build](#build).

## Build

Requires Xcode on an Apple Silicon Mac.

```sh
zsh scripts/build_apps.sh
```

This builds `build/Afterscreen.app` (the sender) and `build/Afterscreen Receiver.app` (the receiver, universal).

The apps are signed with `AFTERSCREEN_SIGN_IDENTITY` when it is set, else with your Apple Development identity. Without either, they are signed ad hoc, and macOS asks for the permissions again after every build.

Tests:

```sh
swift test --package-path Core
swift test --package-path Sender
swift test --package-path Receiver
```

## Limitations

- The iMac's keyboard and mouse are not passed to the Mac.
- Wi-Fi quality depends on the network. Latency spikes show as brief pauses, and a cable avoids them.
- Full-screen video in Chrome on a virtual display runs at about 45–60 fps. Safari holds 60 fps.

## License

MIT. See [LICENSE](LICENSE).

iMac, Mac and macOS are trademarks of Apple Inc. Thunderbolt is a trademark of Intel Corporation. Afterscreen is not affiliated with or endorsed by Apple.
