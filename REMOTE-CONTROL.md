# Remote Control

One application, two roles. HTCommander normally talks to a radio over
Bluetooth; with remote control enabled, the same application can either

- **host** — stay attached to the radio and serve remote clients over a single
  WebSocket endpoint, or
- **client** — run on another device with no radio at all, attach to a host and
  operate it remotely.

It is the same binary and the same codebase in both cases. The role is a
setting, not a separate program.

> This feature is original to this fork. It is opt-in and disabled by default;
> with `Remote Control: Off` the application behaves as upstream does.

---

## Before you forward the port

This feature makes a radio transmittable over a network. Two things follow, and
neither is a technical detail the software can settle for you.

**Transmitting remains your responsibility.** Remote control does not move it:
it stays with the licensed operator, whoever is physically at the machine.
Handing a token to somebody without an operator certificate means your licence
does the transmitting. Whether remote transmitting is allowed where you are —
and under what conditions — is set by your jurisdiction's rules, not by this
project. Documentation here, including this file, is **not legal advice**.

**Exposing the port puts transmit capability on the network.** The host listens
on loopback only until you say otherwise. Once it is reachable from elsewhere,
anyone holding a valid token can transmit on your radio. Hence, concretely:

- terminate TLS in a reverse proxy and keep the application off the public
  internet directly;
- issue one token per device and revoke the ones you stop using — revocation
  disconnects one device, not the station;
- read the audit trail: it records attach, rejected attach, refused writes and
  every transmission, with the token name and client address, and that is the
  only evidence you will have afterwards.

The controls described below — mandatory token authentication, the
single-operator lock, the audit trail, LAN access off by default — are what the
software can do. They reduce the chance of an accident; they do not make remote
operation compliant, and they cannot tell you whether it is permitted.

---

## Configuration

Settings → **Remote Control** → choose a role → **Apply**.

A role change needs an application restart. Changing only the port or address
does not.

| Role | Fields | What happens |
| --- | --- | --- |
| Off | — | Nothing. Default. |
| Host | Listen port, *Accept connections from other devices*, *Stream audio to clients*, Audio quality, *Trust X-Forwarded-For*, Access tokens | Serves `/remote` on that port for authenticated clients |
| Client | Host address (`ws://` or `wss://`), access token | Attaches to that host and mirrors its state |

### This build installs alongside the upstream app

The Android application id is `com.meshcentral.htcommander.remote`, not
upstream's `com.meshcentral.htcommander`. The two are signed with different keys,
so Android refuses to install one over the other
(`INSTALL_FAILED_UPDATE_INCOMPATIBLE`), which would have meant deleting the
official app -- and its settings, channels and tokens -- just to try this fork.
With a separate id both can be installed, each with its own data.

They are otherwise independent: use whichever you are testing with. On desktop
the executable is still `htcommander.exe` and a build replaces the previous one.

### APRS cloud push is not built in

Upstream delivers APRS messages as background push notifications through
Firebase Cloud Messaging, which routes them via Google. This fork removes that
path: no Firebase dependency, no `google-services.json` processing, and the
service is compiled as a no-op. A switch you may have seen in Settings does
nothing here.

Nothing else is affected — local notifications, APRS itself, the maps, Winlink,
the terminal and remote control all work as before. See the fork-vs-upstream
table in the README.

### Two defaults that will surprise you

**The host listens on 127.0.0.1 only.** A client on another machine cannot
connect until you tick *Accept connections from other devices on the network*.
That is deliberate — exposing a radio's control port to a whole LAN should be a
choice you make, not something that happens the first time you pick "Host".

**The host requires a token before any client may attach**, and until you
generate one, nobody can. Issue the first token under **Access tokens** in the
same section: name the device, press *Generate token*, and copy the secret
immediately — it is shown **once** and cannot be recovered. Revoking a token
disconnects only that device.

The **token is held in the platform secret store**, not in the settings file,
and the field is write-only: it is never read back into the UI.

---

## Security model

The design assumes the operator, not the network, is trusted.

**Transport.** The app speaks plain WebSocket. For use across the internet, put
a TLS-terminating reverse proxy (Caddy, nginx, Cloudflare Tunnel) in front and
forward to the listen port; use a `wss://` address on the client. The app does
not implement TLS itself.

**Authentication.** Every attach must present `Authorization: Bearer <token>`.
Tokens are 32 random bytes, are issued per device, and can be revoked
individually. Verification happens **before** the WebSocket upgrade, so a
rejected client never receives one. The response deliberately does not
distinguish "no token" from "wrong token" from "revoked token".

Tokens are never placed in a URL query string, because query strings end up in
reverse-proxy access logs.

**Operator authority.** Any number of clients may attach and watch, but exactly
one holds operator authority at a time. There is **no local pre-emption**: the
operator releases explicitly, loses it on disconnect, or loses it after an idle
timeout — those are the only three release paths, and all three are covered by
tests. Without them a client that dropped off a flaky link would own the
transmitter forever.

What requires operator authority (decision Q11, option C):

| Action | Operator required |
| --- | --- |
| Transmit (uplink audio) | **Yes** |
| Any device-0 settings write | **Yes** |
| `WriteChannel`, `SetRegion`, `SetRegionName` | **Yes** |
| Reading state, listening to audio, history, VFO tuning, radio UI operation | No |

A refused write is answered with `{"m":"refused","reason":"not-operator"}` and
recorded in the audit trail, so a client can say "not the operator" rather than
appear to work and silently do nothing.

**Audit trail.** Attach, rejected attach, detach and refused writes are recorded
with the client address, token id and token name; the host persists them to a
`remote_audit` table when a database is available. `X-Forwarded-For` is
**audit-only**: it is ignored unless explicitly trusted, because only the
operator knows whether a proxy is in front, and a client that can set its own
apparent address must never influence a security decision.

---

## Protocol

A single endpoint, `/remote`, carrying the same message shape the desktop build
already uses between its main window and detached windows. One protocol, two
carriers.

Client → host (JSON text):

| Message | Meaning |
| --- | --- |
| `{"m":"snapshot"}` | Ask for the full broker state |
| `{"m":"dispatch","deviceId":N,"name":"X","payload":"…","store":bool}` | Write a value |
| `{"m":"detach"}` | Release everything this peer attached |
| `{"m":"operator-acquire"}` / `{"m":"operator-release"}` | Take / drop operator authority |

Host → client:

| Message | Meaning |
| --- | --- |
| `{"m":"snapshot","entries":[…]}` | Broker state |
| `{"m":"onData","deviceId":N,"name":"X","payload":"…","store":bool}` | A value changed |
| `{"m":"operator","holderId":…}` | Who currently holds authority |
| `{"m":"refused","name":"X","reason":"not-operator"}` | A write was refused |

Audio travels as **binary** frames in both directions, using the layout the
hosted-web bridge already uses:

```
[0xF1 magic][channels][rateLo][rateHi] + little-endian int16 PCM
```

Direction needs no tagging: a socket carries one peer, so inbound binary is
always uplink (microphone) and outbound binary is always downlink (listening).

Sample rate is carried per frame, so the three tiers (32 / 16 / 8 kHz) need no
protocol change. Downlink above the target rate is filtered by a 4th-order
cascaded biquad before decimation — without it, everything above 4 kHz folds
back onto the speech band.

---

## Current status

Working, and exercised on a phone against a PC:

- Host and client roles, role-driven startup, settings UI
- Broker state mirroring in both directions
- Token authentication, always required for a host, with per-device revocation
  and a UI to issue and revoke them
- Single-operator lock, enforced on transmit, settings, channel and region
  writes, with the holder published so any tab can display it
- Two-way audio: host playback → client speaker, at a selectable 32 / 16 / 8 kHz
  tier; audio streaming is a switch you can turn off for a control-only session
- **Client transmit** (press-and-hold): the microphone opens on the press and
  closes on release or cancel, and the uplink is gated on holding authority, so
  a hot microphone cannot transmit on somebody else's authority
- **The control states which of the three outcomes applies**: available
  (nobody holds it), ready (you hold it), in use: *id* (another client does).
  A bare "not the operator" could not distinguish an idle station from a busy
  one, which is what made the device UI unreadable
- **Authority is kept for five minutes after release**, so consecutive
  transmissions do not race another client each time. The window is one number
  shared by both sides; when the client and host disagreed the host reclaimed it
  after 34 seconds. Speaking counts as activity, so a long transmission is not
  interrupted mid-sentence
- Audit trail recording attach, rejected attach, detach, refused writes, and
  transmissions (one entry per burst, not per frame), persisted when a database
  is available
- Loopback by default with an explicit LAN opt-in, and audit-only
  `X-Forwarded-For`

Not yet proven:

- **One phone, one PC.** Nothing here has been exercised across a range of
  devices, Android versions, NAT setups, or through the TLS reverse proxy the
  design assumes. Treat the feature as working, not as validated.
- **Web is untested for this feature.** The web build exists and remote control
  is not compiled out of it; nobody has driven a session from a browser.
- **iOS contributes only control.** It builds upstream, but no remote audio path
  has been tried there.

---

## Verification

```bash
flutter analyze
flutter test
```

The remote-control code is covered by 17 test files (~90 tests) alongside the
existing suite, which is 628 tests in total.
