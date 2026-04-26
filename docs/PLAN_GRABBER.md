# `skhd-grabber` — system daemon for caps_lock-class tap-hold

Hybrid (Option D) plan to support `.remap caps_lock { … }` and other
sources where macOS's HID layer prevents the user-agent path from
working. Layered on top of the existing user-agent skhd, opt-in.

## Why two binaries

macOS's `IOHIDDeviceOpen(kIOHIDOptionsTypeSeizeDevice)` requires root,
and the Karabiner DriverKit `vhidd_server` daemon refuses non-root
clients. Tap-hold for caps_lock therefore can't live in the per-user
user-agent. But also: users who don't need caps_lock tap-hold should
not pay any cost (no system daemon, no system extension on their
machine, no root processes). Hence the split:

- **`skhd`** — per-user agent (today's model). Handles all
  CGEventTap-based features: regular hotkeys, modes, process lists,
  `.device` matching, `.remap` colon-form for non-caps targets via
  hidutil. **Unchanged install path**, runs as the user.
- **`skhd-grabber`** — system daemon, root. Owns the seize on
  configured devices, runs the tap-hold state machine on the seized
  HID stream, injects results through Karabiner's virtual HID device.
  **Opt-in** via `skhd --install-grabber`.

Communication: the user-agent talks to the grabber through a Unix
domain socket when (and only when) the user's config contains a
caps-class `.remap {}` rule.

## Architecture

```
┌─ User A session ──────────────┐  ┌─ User B session ─────────────┐
│ skhd (user agent, today)      │  │ skhd (user agent, today)     │
│ • CGEventTap                  │  │ • CGEventTap                 │
│ • [device guard]              │  │ • [device guard]             │
│ • non-caps .remap (hidutil)   │  │ • non-caps .remap (hidutil)  │
│ • regular hotkeys             │  │ • regular hotkeys            │
└────────────┬──────────────────┘  └────────────┬─────────────────┘
             │ Unix socket only when            │
             │ config has caps .remap{}         │ (no socket — no caps rule)
             ▼
┌──────────────────────────────────────────────────────────────────┐
│ skhd-grabber (system daemon, root, optional)                     │
│ • Listens on /var/run/skhd/grabber.sock                          │
│ • Tracks console user via SCDynamicStoreCopyConsoleUser          │
│ • Per-user rule sets (only active user's apply)                  │
│ • IOHIDDeviceOpen(seize) on matched devices                      │
│ • TapHoldMachine on seized HID stream                            │
│ • Injects via Karabiner vhidd Unix socket                        │
└─────────────┬────────────────────────────────────┬───────────────┘
              ▼                                    ▼
       Real keyboards                Karabiner-DriverKit-VirtualHIDDevice
       (seized; kernel sees           (already-installed signed dext;
        nothing while held)            we are a client)
```

## What's reused vs. new

**Reused (no churn):**
- All existing user-agent code: `Parser.zig`, `Tokenizer.zig`,
  `Hotkey.zig`, `Mappings.zig`, `EventTap.zig`, `Mode.zig`,
  `CarbonEvent.zig`, `Hidutil.zig`, `HidMonitor.zig`.
- `.device`, `.remap` (colon and block) parsing.
- The `TapHoldMachine` design — but it'll need a refactor to
  accept HID events instead of CGEvents (the abstraction is small
  enough that one struct can cover both).

**New code:**
- `src/grabber/` — new binary's sources.
  - `main.zig` — daemon entry, launchd integration.
  - `Vhidd.zig` — Karabiner virtual-HID-device client (Unix socket
    protocol to `vhidd_server`).
  - `Seize.zig` — `IOHIDDeviceOpen(seize)` per device, value-callback
    handling.
  - `RuleSet.zig` — per-user rules, switched on console-user change.
  - `Ipc.zig` — Unix socket server for the user-agent IPC.
- `src/agent_grabber_client.zig` — IPC client used by the user-agent
  to push rules to the grabber when configured.
- New CLI: `skhd --install-grabber`, `--uninstall-grabber`,
  `--grabber-status`.

**Modified:**
- `Mappings.zig` — partition `tapholds` into "caps-class"
  (handled by grabber) and "non-caps" (handled by user-agent's
  CGEventTap). The user-agent forwards the caps-class set to grabber.
- `skhd.zig` (user-agent) — at startup, if `mappings.tapholds` has
  any caps-class entries, dial the grabber socket; on parse-reload,
  resend.

## Key design decisions

### 1. Where does config live?

Agent owns config. Per-user `~/.config/skhd/skhdrc` parsed by the
user-agent; the agent ships the parsed caps-class subset to the
grabber over the socket. Grabber is stateless re: content — it
holds whatever the agent gave it for the current console user.

Rationale: preserves per-user separation. Grabber doesn't read user
files (avoids privilege boundary issues). Each user's
caps-class rules only ever apply during their session.

### 2. Console-user tracking

Grabber subscribes to `kSCDynamicStoreDomainState/Console User` via
`SCDynamicStoreNotificationCallBack`. On change:
- Apply the new console user's rule set (if any agent is connected
  for that uid).
- Pause the previous user's rules.
- If no active rule set, release seize on all devices.

Fast user switching: ~hundreds of ms gap during which the keyboard
behaves natively. Acceptable.

### 3. When does grabber seize?

Only when there's at least one caps-class rule for the active
console user. No active rules → no seize → keyboard fully native.
Adding a rule (config reload by agent) → grabber re-evaluates and
seizes if needed.

### 4. Coexistence with Karabiner-Elements

Both share the same Karabiner DriverKit dext. Karabiner-Elements
also seizes devices. Conflict on a given device: first seizer wins,
second gets `kIOReturnExclusiveAccess`. Detect on grabber startup
and log a clear warning ("Karabiner-Elements is seizing this device
— skhd's caps tap-hold won't apply to it").

### 5. What happens on grabber crash

`IOHIDDeviceOpen` reclaim on process death is the kernel's job.
launchd respawns. Agent's socket connection drops; agent retries
with backoff. ~1–3s of native keyboard behaviour, then back online.

### 6. What if user installs grabber but vhidd dext isn't installed

Grabber checks at startup via `systemextensionsctl list` (or by
attempting socket connect to `vhidd_server`). On failure: log a
clear error pointing at pqrs.org's installer URL, refuse to start.
launchd will keep retrying — when user installs the dext and
reboots, grabber comes up.

### 7. What if user-agent has caps rule but grabber isn't installed

Agent's socket connection fails. Log a `warn`-level diagnostic
("caps_lock tap-hold rule found but skhd-grabber is not installed
or running. Run `skhd --install-grabber` to enable.") and continue
without caps support. Other rules still work.

### 8. Out of scope for D

- Multiple simultaneously-active users (Sharing, Caching) — only
  the console user's rules apply.
- Phase 4 layer holds (`hold: fn_layer`) — keep deferred to its
  own phase. Once the grabber pipeline exists, layer holds slot in
  on top of it.
- Auto-install of vhidd dext (we ask user to install pqrs.org's
  signed pkg manually; skhd points at the URL).

## IPC protocol

Length-prefixed JSON messages over `/var/run/skhd/grabber.sock`
(grabber-side socket, mode 0666, ACL'd to local console users).

**Agent → grabber:**
```json
{"type": "hello", "uid": 501, "version": 1}
{"type": "apply_rules", "rules": [
   {"src_usage": 0x39, "tap_usage": 0x29, "hold_usage": 0xE0,
    "device": {"vendor": 0x05AC, "product": 0x0342},
    "timeout_ms": 120, "permissive_hold": true,
    "hold_on_other_key_press": false, "retro_tap": false}
]}
{"type": "bye"}
```

**Grabber → agent:**
```json
{"type": "ok"}
{"type": "error", "code": "vhidd_not_installed", "message": "..."}
{"type": "warn", "code": "device_seized_by_other", "device": "0x05AC:0x0342"}
```

## Install / uninstall flow

`skhd --install-grabber`:
1. Check `systemextensionsctl list` for `org.pqrs.Karabiner-DriverKit-VirtualHIDDevice`. If absent, print install link, abort.
2. Sudo-escalate (or instruct user to re-run with sudo).
3. Copy `skhd-grabber` binary to `/usr/local/libexec/skhd-grabber`.
4. Write `/Library/LaunchDaemons/com.jackielii.skhd.grabber.plist`
   with `RunAtLoad=true`, `KeepAlive=true`, `ProcessType=Interactive`.
5. `launchctl bootstrap system /Library/LaunchDaemons/...`.
6. Verify daemon is running and reachable on the socket.

`skhd --uninstall-grabber`:
1. `launchctl bootout system /Library/LaunchDaemons/...`.
2. Remove plist and binary.
3. (User may also want to uninstall pqrs.org dext separately.)

## Phasing & estimates

### D1 — grabber skeleton (2–3 days)
- New binary `src/grabber/main.zig` builds & runs.
- Unix socket server with hello/apply_rules/bye protocol.
- launchd plist + install/uninstall scripts.
- Agent stub: detects caps rule in config, dials socket, sends
  apply_rules, gets `ok` back. No actual HID work yet.

### D2 — Karabiner vhidd client (2–3 days)
- Connect to `/Library/Application Support/org.pqrs/tmp/rootonly/vhidd_server/*.sock`.
- Implement the small protocol surface needed for keyboard injection
  (Karabiner publishes the protocol — we'd port it from their C++
  client lib to Zig).
- Test injection: send a simulated `escape` keydown/up, verify it
  shows up in the focused app.

### D3 — HID seize (2–3 days)
- `IOHIDDeviceOpen(kIOHIDOptionsTypeSeizeDevice)` on the (vendor,
  product) pairs supplied by the active rule set.
- Input value callback receiving raw HID events from seized device.
- Pass-through events not matched by any rule (synthesize identical
  events through vhidd so the user can keep typing while we hold the
  seize).

### D4 — TapHoldMachine on seized stream (2–3 days)
- Refactor `TapHoldMachine` to accept HID events directly (it
  currently takes CGEvents). Both call sites can use the same state
  machine — only event types differ.
- caps_lock specifically: source key arrives as raw HID 0x39 from
  the seized device; tap action emits HID 0x29 (escape) via vhidd;
  hold action emits HID 0xE0 (lctrl). No more F18 proxy.
- All four QMK knobs (timeout / permissive_hold /
  hold_on_other_key_press / retro_tap) work as before.

### D5 — per-user lifecycle (2–3 days)
- `SCDynamicStoreCopyConsoleUser` polling or notification.
- Switch active rule set on console-user change.
- Release / acquire seize as needed.
- IPC: track per-uid client connections.

### D6 — polish (1–2 days)
- `skhd --install-grabber`, `--uninstall-grabber`,
  `--grabber-status`.
- Failure paths: dext missing, vhidd_server down, seize race with
  Karabiner-Elements.
- README docs + clear startup messages from the user-agent when
  grabber is needed but not running.

**Total: ~2.5 weeks of focused work.**

## Risk register

- **Karabiner DriverKit protocol changes**: their client lib gets
  versioned releases. Pin to a known-working version, document in
  README, update when needed.
- **Apple changes DriverKit policies**: low likelihood given
  Karabiner's track record on Apple Silicon Tahoe, but if Apple
  tightens further, the entire approach (and Karabiner) is at risk.
  Mitigation: keep a fallback to the F18-proxy / right_alt path so
  users have *some* tap-hold even if the dext stops working.
- **vhidd_server crashes**: launchd respawns; we reconnect with
  backoff. ~1–3s gap per crash.
- **User installs grabber, then uninstalls vhidd dext**: grabber
  fails to start. Loud error message; uninstall instructions in
  README.

## What to commit incrementally

Each Dn ends in a runnable state:
- After D1: socket plumbing, install scripts work, end-to-end
  rule-pass-through is testable (no actual injection).
- After D2: prove vhidd injection works with a hard-coded escape
  stream.
- After D3: prove seize works (verify seized keyboard is "dead" to
  other apps, all events flow only to grabber).
- After D4: end-to-end caps_lock tap-hold for the active user.
- After D5: multi-user behaviour matches design.
- After D6: install instructions + docs are user-ready.
