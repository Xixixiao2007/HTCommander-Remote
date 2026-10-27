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

## Configuration

Settings → **Remote Control** → choose a role → **Apply**.

A role change needs an application restart. Changing only the port or address
does not.

| Role | Fields | What happens |
| --- | --- | --- |
| Off | — | Nothing. Default. |
| Host | Listen port (blank = any free port) | Serves `/remote` on that port for authenticated clients |
| Client | Host address (`ws://` or `wss://`), access token | Attaches to that host and mirrors its state |

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

Working:

- Host and client roles, role-driven startup, settings UI
- Broker state mirroring in both directions
- Token authentication with per-device revocation
- Single-operator lock, enforced on transmit, settings, channel and region writes
- Two-way audio: host playback → client speaker; client microphone → 32 kHz frames
- Audit trail, persisted when a database is available
- Configurable bind address and audit-only `X-Forwarded-For`

Not yet wired:

- The OS microphone capture device and injecting received audio into the host's
  transmit chain (the wire seam and rate conversion are done and tested)
- A UI for issuing and revoking tokens (the store and enforcement are done)

---

## Verification

```bash
flutter analyze
flutter test
```

The remote-control code is covered by 13 test files (~80 tests) alongside the
existing suite.
