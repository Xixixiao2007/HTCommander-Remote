# ADR 0001 — Which radio a remote operator's voice is transmitted on

**Status:** Proposed — awaiting maintainer decision.
**Date:** 2026-01 (recorded while implementing slice T5d-b)
**Deciders:** fork maintainer (`Xixixiao2007`)

> This record deliberately does **not** decide. It exists so the remaining
> decision costs one word instead of a re-derivation of the whole analysis. The
> implementation seam is already in place and waiting for the answer; see
> "What the answer changes" at the end.

---

## Context

The remote-control feature lets one HTCommander instance act as a *host*
(attached to a radio) while another instance acts as a *client* (no radio).
Decisions D1–D8, already confirmed:

- **D2** the remote operator gets full functionality, including transmit.
- **D5** exactly one peer holds operator authority at a time, and **only the
  operator may transmit**.

D5 answers *who* may key a transmitter. It does not answer *which* transmitter.

A host may have several radios attached simultaneously — the application
supports this for local use, where "the radio in use" is whichever the operator
has selected in the main window. Remotely that context is invisible: the client
cannot see which radio the host's UI has selected, and the host cannot know
which station the remote operator believes they are keying.

On amateur bands, keying the wrong station is not a cosmetic bug. It can
transmit on the wrong frequency, under the wrong band plan, or through an
antenna the operator did not intend to use. It is also a regulatory matter, not
only a UX one.

## Options

| | Rule | Advantages | Costs |
| --- | --- | --- | --- |
| **A** | Key the radio currently selected on the host (identical to local PTT) | Exactly one mental model for both local and remote operation; "the selected radio" is already the operator's expressed intent; needs no protocol change | A remote operator who cannot see the host's selection may be surprised. Mitigation: publish the target radio's identity (device id / name) so the client can display it |
| **B** | Key the first connected, powered radio | Trivial to implement | **Silently keying the wrong station when several are attached** — the failure mode this ADR exists to prevent |
| **C** | Client names the target radio in the protocol | Most explicit and flexible; scales to genuinely multi-radio remote operation | Protocol change plus client UI; the client must be told the available radios before it can choose, which is a second protocol addition |
| **D** | Allow remote transmit only when exactly one radio is attached; refuse otherwise | Safest possible; no ambiguity by construction | Multi-radio users cannot transmit remotely at all, and the refusal has to be surfaced clearly or it looks broken |

## Recommendation

**Option A**, with the target radio published to the client for display.

Reasons:

1. It preserves a single mental model. Local PTT already transmits on the
   selected radio; a remote operator who is also a local operator does not have
   to learn a second rule for the same action.
2. "Currently selected" is the closest available proxy for intent — it is the
   host operator's expressed choice, not a guess based on connection order.
3. It needs no protocol change to become correct, only a displayed identity, so
   it can ship now and be extended to C later without rework.
4. B's failure mode is silent and wrong-station; that is disqualifying for a
   transmit path regardless of how simple it is.

## What the answer changes

Deliberately small, because the seam was built to absorb it:

- `RemoteTxInjector` already takes `deviceId` as a constructor argument and
  refuses to choose one itself. Once decided, the wiring passes either a fixed
  id, a resolver callback (A and B), or a client-supplied id (C).
- Everything else in the transmit path is finished and tested: rate conversion,
  pre/post silence, the `hold` stream, the idle stall watchdog (the voice path
  has no other watchdog — an unreleased stream would keep the radio
  transmitting), the operator-authority gate, and the transmit audit entry.

Options C and D additionally require host-side work to refuse or route, plus
client UI; those costs are why they are listed rather than assumed.

## Consequences of not deciding

Remote transmit stays unwired. The host accepts and audits the client's
authority handshake and its audio, and drops the audio without keying anything.
That is the safe failure direction, but it means "the client can talk" is not
true yet even though every part of the path up to the radio is implemented.
