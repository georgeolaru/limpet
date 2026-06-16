# Design: prefer macOS native Auto-Join Hotspot, fall back to password join

Date: 2026-06-16
Status: accepted

## Problem

On the same Apple ID, iOS 26 / macOS Tahoe 26 add **Auto-Join Hotspot**: when no
Wi-Fi is available, the Mac joins a same-Apple-ID (or Family Sharing) iPhone's
Personal Hotspot over Bluetooth — *including a dormant hotspot*, which solves the
old "keep the Personal Hotspot screen open" problem. Limpet's password join
(`networksetup`) cannot wake a dormant hotspot, so for same-Apple-ID users the OS
can now do the join more reliably than Limpet.

## Key constraint (researched)

There is **no supported way for a shell script to *trigger* Instant Hotspot /
Continuity** — Apple exposes it only as a GUI action and as the native Auto-Join
setting. So Limpet cannot perform the Continuity join itself. The realistic design
is to **yield to** macOS's native Auto-Join and verify, then fall back.

## What Limpet still owns (why it's not redundant)

macOS Auto-Join only fires when **"no Wi-Fi is available."** It does nothing when
you're connected to a Wi-Fi that is up but has **no real internet** — the most
common silent-offline case. Limpet remains the **watchdog/verifier**:
- detects "connected but no real internet" (ping + HTTP + HTTPS probes);
- gets off the dead network so Auto-Join can fire;
- confirms working internet;
- manages the return to real Wi-Fi;
- covers Android / different-Apple-ID phones via the password join.

## Design — remediation change

In `remediate()` (section 8 of `limpet.sh`), insert an **Auto-Join yield** between
phase C1 (preferred networks) and C2 (password hotspot join):

```
ensure_wifi_on
A) wait_for_link + probe         # macOS auto-reconnect
B) wifi_bounce + probe           # fix "connected but dead"
C) scan
   C1) try_preferred_networks
   C-NEW) if PREFER_AUTOJOIN_HOTSPOT: wait_for_autojoin()   # ← new
   C2) try_hotspot (password join)
```

`wait_for_autojoin()` polls `probe_internet` every few seconds up to
`AUTOJOIN_WAIT_SECS`. During this window the Mac has no good Wi-Fi, so macOS's
native Auto-Join can grab the (possibly dormant) same-Apple-ID hotspot. On success
→ `log "Recovered via macOS Auto-Join Hotspot."` and return 0. On timeout → fall
through to the existing password join (Android / other Apple ID / feature off).

## New config (section 1 defaults + `config.example.sh`)

- `PREFER_AUTOJOIN_HOTSPOT=1` — yield to native Auto-Join before the password join.
  Android-only setups can set `0` to skip the wait.
- `AUTOJOIN_WAIT_SECS=15` — how long to give macOS to auto-join.

## Honest constraint

macOS Auto-Join needs "no Wi-Fi available." For the *connected-but-dead* Wi-Fi
case, Limpet must get off the network first, and modern macOS has no clean
"disconnect but keep Wi-Fi on" CLI. We rely on the existing `wifi_bounce` +
the yield window; it's **best-effort** for that edge. The pure "no network around"
case (left the building) hands off to Auto-Join cleanly.

## Docs (README + config)

- New **"Same Apple ID (recommended)"** subsection: enable *Wi-Fi Settings → "Ask
  to join hotspots" → Automatic*, keep Bluetooth on (macOS 26+). Explain Limpet's
  watchdog/verifier role and what it adds over native Auto-Join. Include Apple
  links: [109321](https://support.apple.com/en-us/109321),
  [111785](https://support.apple.com/en-us/111785).
- Fix the "keep the hotspot screen open" caveat → applies only to the password
  path (Android / different Apple ID); same-Apple-ID gets the Bluetooth wake.
- A short **real-world setup** note: Amphetamine/`caffeinate` keeping the Mac
  awake, lid open, in a bag — the canonical use case.
- Document the two new config keys.

## Testing

- `bash -n limpet.sh` + `tests/run.sh` (syntax/integration).
- Behavioral verification needs real hardware (a same-Apple-ID iPhone) — note in
  the PR; can't be unit-tested in the shell.

## Out of scope (YAGNI)

- UI-scripting the Wi-Fi menu to force Instant Hotspot (fragile; rejected).
- Detecting same-Apple-ID / the Auto-Join setting state from the CLI (not
  reliably possible; we just yield and verify).
