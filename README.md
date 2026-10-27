# HTCommander-Remote

**English** | [简体中文](README.zh-CN.md)

A fork of [Handi-Talky Commander](https://github.com/Ylianst/HTCommander) that
adds **native remote control**: the same application can either attach to a
radio and serve remote clients, or run as a secondary client of such a host.

> **This is a modified derivative, published under the Apache License 2.0.**
> It is not the official distribution, and the upstream author is not
> responsible for the changes made here. See [NOTICE](NOTICE) for the statement
> of changes required by Apache-2.0 §4(b), and
> [Ylianst/HTCommander](https://github.com/Ylianst/HTCommander) for the original
> project.

---

## What this fork adds

| | Upstream | This fork |
| --- | --- | --- |
| Local use (radio over Bluetooth) | Yes | Yes — unchanged |
| **Host role**: serve remote clients | No | **Yes** — token auth, single-operator lock, audit trail |
| **Client role**: operate a remote host | No | **Yes** — mirrors the broker state, two-way audio |
| Audio quality tiers | — | **32 / 16 / 8 kHz**, selectable |
| Transmit from the remote end | — | **Yes**, press-to-talk, gated on operator authority |

The feature is **opt-in**. Left at its default (`Settings → Remote Control →
Off`), the application behaves exactly as upstream does.

Start here: **[REMOTE-CONTROL.md](REMOTE-CONTROL.md)** — the design, the
security model, how to configure host and client, and what is not wired yet.

Two defaults worth knowing before you try it:

1. **The host listens on `127.0.0.1` only.** A client on another machine cannot
   connect until you tick *Accept connections from other devices on the network*.
2. **The host requires a token, and starts with none.** Issue one under
   *Access tokens* in the same settings section, and copy the secret
   immediately — it is shown once.

---

## ⚠️ Legal and compliance risk of network forwarding

**Read this before forwarding any port.**

### Responsibility for transmitting does not travel with the connection

Transmitting with this software assumes you hold a valid operator certificate and
station authorisation **where you are**. The requirements differ by jurisdiction
and are outside the scope of this document — check them yourself.

Remote control does not change who is responsible: that stays with the licensed
operator, regardless of who is physically sitting at the machine. So:

- Handing a token to someone without an operator certificate means **your**
  licence does the transmitting.
- Transmitting through someone else's host is still governed by your own
  jurisdiction's rules.
- Remote operation routinely means "nobody is at the station", and that
  situation carries extra conditions in many places.

**Whether remote transmitting is permitted, and to what extent, is decided by the
rules where you are — not by this project.** This document is **not legal
advice**, and neither is the rest of the project's documentation.

### Exposing the port puts transmit capability on the network

By default the host listens on loopback only. The moment you enable LAN access,
or forward the port through a reverse proxy to the internet, the situation
changes: **anyone holding a valid token can transmit on your radio.**

Concretely:

- **Do not expose the port directly to the internet.** Terminate TLS in a
  reverse proxy (Caddy, nginx, Cloudflare Tunnel, …) and keep the application
  on the internal network.
- **Issue one token per device and revoke what you stop using.** A leaked token
  is disconnected individually, without disturbing the others.
- **Read the audit trail.** The host records every attach, every rejected
  attach, every refused write, and every transmission, with the token name and
  the client address. That is your evidence after the fact.

### What the software does and does not give you

| Provided | Not provided |
| --- | --- |
| Mandatory token authentication, on by default for a host | **Any compliance guarantee** |
| Single-operator lock: only the holder can transmit | A judgement on whether you may transmit remotely at all |
| Full audit trail (attach, reject, write, transmit) | Automatic limits on regulated bands or power |
| LAN access off by default | Encryption of the hop (TLS is the proxy's job) |

Compliance is between you and your regulator. The software can only record who
did what.

---

## Getting a build

### ⚠️ Pre-built packages: available, and handled with tongs

Packages are attached to [Releases](https://github.com/Xixixiao2007/HTCommander-Remote/releases)
for **Windows (x64), Android, and Web**.

**Read this before you install one.** These are built on one machine by the
maintainer, not by a release pipeline, and they have had very little field
testing:

- **They may not work.** Remote control has been exercised on exactly one
  phone talking to exactly one PC. Everything else is unproven.
- **Only Windows was run end-to-end here.** Android installs and launches; the
  remote session was then verified on it. Web builds; nobody has driven a
  remote session from a browser.
- **Linux and macOS have no packages.** They cannot be built on a Windows
  machine, and this fork has no working release pipeline (upstream's needs
  signing certificates this fork does not have). Build from source.
- **Nothing is code-signed**, so Windows SmartScreen and macOS Gatekeeper will
  warn. That warning is accurate: nobody has audited these binaries but you.
- **No updates.** The self-updater points at upstream's release channel, which
  does not carry this fork's builds — expect it not to offer you anything.

If a package misbehaves, building from source below is the reliable path, and
an issue describing what happened is welcome.

### Build from source

Requires [Flutter](https://docs.flutter.dev/get-started/install). This fork is
developed against **Flutter 3.47.8 / Dart 3.13.7**.

```bash
cd src
flutter pub get
flutter build windows --release      # or: build linux / build macos / build apk / build ios
```

On Windows, two environment quirks were needed to build cleanly here:

```powershell
$env:CL = '/utf-8'                              # source files are UTF-8; the default code page breaks
$env:CMAKE_POLICY_VERSION_MINIMUM = '3.5'       # CMake 4 rejects the pinned plugin minimums
```

Building with plugins also requires **symlink support**: enable Windows
Developer Mode, or run the shell as administrator.

For Android, the toolchain expects **JDK 17+** and an SDK platform that matches
`compileSdk` (37 at the time of writing). `flutter doctor` names whatever is
missing.

### Or: use the upstream build, and lose this fork's feature

If you only want the base application, the
[upstream releases](https://github.com/Ylianst/HTCommander/releases) are the
right binaries — they are the original project, supported by its author. They
do **not** include remote control.

---

## Upstream features (unchanged here)

An Amateur Radio (HAM Radio) multiplatform tool for EchoLink and the UV-Pro,
UV-50Pro, GA-5WB, VR-N75, VR-N76, VR-N7500, VR-N7600 radios, on Windows, macOS,
Linux, iOS, Android and web, given Bluetooth support.

An Amateur radio license is required to transmit using this software. You can
get [information on a license here](https://www.arrl.org/getting-licensed).

### Radio support

EchoLink and the following radios should work:

- BTech UV-Pro, UV-50Pro
- Radioddity GA-5WB, DB50-B Mini
- Vero VR-N75, VR-N76, VR-N7500, VR-N7600
- Radtel RT-660

### Features available on all platforms

- [Channel Programming](https://ylianst.github.io/HTCommanderSite/features/channels.html). Configure, import, export and drag & drop channels.
- [APRS support](https://ylianst.github.io/HTCommanderSite/features/aprs.html). Receive and send APRS messages, set routes, send SMS to phones, request weather, send authenticated messages.
- [BSS support](https://ylianst.github.io/HTCommanderSite/features/bss.html). The proprietary short-message binary protocol from Baofeng / BTech.
- [APRS map](https://ylianst.github.io/HTCommanderSite/features/map.html). Open Street Map, all APRS stations at a glance.
- [Winlink mail support](https://ylianst.github.io/HTCommanderSite/features/winlink.html). Email over the Winlink network, with attachments.
- [Address book](https://ylianst.github.io/HTCommanderSite/features/address-book.html). APRS, Winlink and Terminal contacts.
- [Terminal support](https://ylianst.github.io/HTCommanderSite/features/terminal.html). Packet mode with stations, users and BBSes.
- [BBS support](https://ylianst.github.io/HTCommanderSite/features/bbs.html). A basic built-in BBS that also acts as a Winlink gateway.
- [Packet Capture](https://ylianst.github.io/HTCommanderSite/features/capture.html).
- [GPS Support](https://ylianst.github.io/HTCommanderSite/features/gps.html). If your radio firmware exposes it.
- [Torrent file exchange](https://ylianst.github.io/HTCommanderSite/features/torrent.html). Many-to-many over 1200 baud FM-AFSK.

### Also on Windows, Linux, macOS, Android

- [Bluetooth Audio](https://ylianst.github.io/HTCommanderSite/features/bluetooth-audio.html). Listen and transmit with speakers, microphone or headset.
- [SSTV](https://ylianst.github.io/HTCommanderSite/features/sstv.html) send and receive images; reception is auto-detected.
- [Speech-to-Text](https://ylianst.github.io/HTCommanderSite/features/voice.html) and text-to-speech.

### Desktop only (Windows, Linux, macOS)

- [AGWPE Protocol](https://ylianst.github.io/HTCommanderSite/features/agwpe.html). Route other applications' traffic over the radio.

---

## License and attribution

- **License:** [Apache License 2.0](LICENSE), unchanged from upstream. This fork
  does not relicense anything.
- **Changes:** [NOTICE](NOTICE) records what was added and which files carry it.
- **Original project:** [Ylianst/HTCommander](https://github.com/Ylianst/HTCommander)
  — the official distribution and the place to report issues that reproduce
  without this fork's remote-control feature.
- **Upstream web site:** <https://ylianst.github.io/HTCommanderSite/>

### Credits

This tool is based on the decoding work done by Kyle Husmann, KC3SLD and the
[BenLink](https://github.com/khusmann/benlink) project, which decoded the
Bluetooth commands for these radios. Also
[APRS-Parser](https://github.com/k0qed/aprs-parser) by Lee, K0QED.

Map data provided by [openstreetmap.org](https://openstreetmap.org).

APRS message backfill uses the [aprs.fi](https://aprs.fi) API, courtesy of
Heikki Hannikainen, OH7LZB.

Repeater directory search is powered by [RepeaterBook](https://www.repeaterbook.com).
RepeaterBook access requires each user to generate their own personal API token.
