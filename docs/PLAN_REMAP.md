# `.remap` Implementation Plan

Phased delivery for the `.remap` + `.device` features. Each phase ships a
testable slice. Design decisions and rationale are not repeated here — see
the design transcript for context.

Supersedes [PLAN_ADVANCED_FEATURES.md](PLAN_ADVANCED_FEATURES.md), which
predates the unified design.

---

## Phase 1 — Device foundation

**Goal:** identify the source device of every keyboard event, with no
ergonomic surface yet. Pure plumbing.

**Deliverables:**

- `src/HidMonitor.zig` — `IOHIDManager` wrapper. Enumerates keyboard-class
  HID devices on startup; subscribes to plug/unplug notifications;
  subscribes to input value events (read-only, no seize). Each value event
  is appended to a fixed-size ring buffer of
  `(mach_timestamp, vendor_id, product_id, usage, value)`.
- `src/DeviceRegistry.zig` — alias map (`name → (vendor, product)`) +
  currently-connected set. Updated by `HidMonitor` on hotplug.
- `src/EventCorrelator.zig` — given a `CGEvent`, look up its
  `(timestamp, raw_keycode)` against the ring buffer to find the source
  device. Bounded search window (recommend 5ms; tune empirically).
- `src/c.zig` — bindings for `IOHIDManagerCreate`, `IOHIDValueGetTimeStamp`,
  `IOHIDDeviceGetProperty`, `kCGEventSourceUserData`, etc.
- `src/Parser.zig` — parse
  `.device <name> { vendor: 0x..., product: 0x... }`. Field order is
  free, comma between fields is optional. Unknown field names error
  loudly so future extension (transport, serial, …) is unambiguous.
- `src/Tokenizer.zig` — adds Token_BeginBlock / Token_EndBlock for
  `{` / `}` and a Token_Colon emitted while `block_depth > 0`. Outside
  blocks, the existing colon-grabs-to-newline behavior is unchanged so
  hotkey rules and `.define` declarations are unaffected.
- `src/main.zig` — `--list-devices` subcommand: print currently-connected
  HID keyboards with copy-pasteable `.device` declarations.
- ~~`src/EventTap.zig` — re-entry guard~~ already implemented
  (`SKHD_EVENT_MARKER` set on synthesized events at `skhd.zig:562-563`,
  checked at `skhd.zig:353-357,401-405`). No work needed.
- **Lazy enable**: `HidMonitor` only starts if `.device` is declared *and*
  referenced by some rule. No overhead for users who don't use the feature.

**Test surface:**

- `zig build run -- --list-devices` prints every connected keyboard.
- Verbose-mode log shows successful correlation: every key event tagged
  with its source device.
- Hotplug a keyboard mid-session → device appears in registry without
  restart.
- Existing skhd functionality unchanged when no `.device` is declared
  (no IOHIDManager spin-up).

**Phase 1 syntax:**

```
.device builtin { vendor: 0x05AC, product: 0x0342 }
ctrl - h [device builtin] : echo "from built-in"
```

The brace block uses the new Token_BeginBlock / Token_Colon / Token_EndBlock
tokens. The device guard `[device <name>]` reuses the existing process-list
bracket and intentionally avoids `:` (the bracket interior keeps the
existing command-grabbing colon semantics for `[ "app" : cmd ]` lists).

**Files added:** `HidMonitor.zig`, `DeviceRegistry.zig`,
`EventCorrelator.zig`. **Files modified:** `Parser.zig`, `Tokenizer.zig`,
`EventTap.zig`, `main.zig`, `skhd.zig`, `c.zig`.

---

## Phase 2 — `.remap` colon form (plain HID remap)

**Goal:** ship the simplest user-visible feature — declarative
`.remap X [device:Y] : Z` — backed by `hidutil` with proper crash recovery.

**Deliverables:**

- `src/Hidutil.zig` — apply/restore `UserKeyMapping` per-device via
  `hidutil property --matching … --set …`. Uses `std.process.Child` for
  the shell-out.
- `src/HidutilState.zig` — state file at
  `~/.cache/skhd/hidutil_state.json` containing
  `{pid, started_at, original: {…}, applied: {…}}`. Written *before* each
  apply, deleted on clean exit.
- Signal handlers for `SIGTERM`, `SIGINT`, `SIGHUP` → restore from
  in-memory snapshot.
- Startup recovery: if state file exists and `pid` is no longer running,
  restore `original` before applying current config's remaps.
- `src/Parser.zig` — parse `.remap <key> [device:<alias>] : <target>`.
  Device guard required for hidutil remaps (without it, parser warns and
  applies globally — risky, but explicit).
- `src/Hotkey.zig` — extend with optional device guard field.
- Conflict detection at parse time: same `(key, device)` claimed twice
  by `.remap` → `ParseError.RemapConflict`.

**Test surface:**

- `.remap caps_lock [device:builtin] : lctrl` → caps acts as ctrl in all
  apps. Cmd-key combos via caps (e.g., caps+a → ctrl+a) work.
- HHKB caps_lock unaffected (per-device matching works).
- `kill -TERM <skhd>` → caps restored to default.
- `kill -9 <skhd>` then re-launch → caps restored on next startup
  (state-file recovery).
- Two `.remap` for same key+device → parse error with line number.

**Files added:** `Hidutil.zig`, `HidutilState.zig`. **Files modified:**
`Parser.zig`, `Hotkey.zig`, `Mappings.zig`, `main.zig`, `skhd.zig`.

---

## Phase 3 — `.remap` block form, state machine

**Goal:** the headline feature — tap-hold dual-function keys.

**Deliverables:**

- `src/TapHoldMachine.zig` — per-rule state machine. States:
  `idle → pending → committed_tap | committed_hold`. Driven by
  `CGEventGetTimestamp(event)` for event timing, `CFRunLoopTimer` for
  timeout fires (one timer per rule, pre-allocated, reused via
  `CFRunLoopTimerSetNextFireDate`).
- Knobs: `timeout`, `permissive_hold`, `hold_on_other_key_press`,
  `retro_tap`. Defaults: `timeout=200ms`, `permissive_hold=on`,
  `hold_on_other_key_press=off`, `retro_tap=off`.
- Auto-proxy for caps-class keys: when `.remap caps_lock { … }` is
  declared, internally hidutil-remap caps→F18 (per-device); state machine
  intercepts F18 events. User still writes `caps_lock` in config.
- Auto-repeat preservation: track `last_tap_time` per rule; if next press
  within `timeout` of last release, treat as plain repeated tap (skip
  state machine for that press).
- Event suppression + synthesis: pending events are buffered; on commit,
  the chosen action's events are synthesized via `CGEventPost` with
  `kCGEventSourceUserData = 'skhd'` set.
- `src/Parser.zig` — parse the block form with the four knobs.
- Conflict detection: `.remap X : Y` and `.remap X { … }` both targeting
  same `(key, device)` → parse error.

**Test surface:**

- `.remap caps_lock [device:builtin] { tap: escape, hold: lctrl, timeout: 120ms, permissive_hold: on, retro_tap: off }`:
  - Quick tap → escape.
  - Hold + a → ctrl-a.
  - Hold alone past timeout, release → no output (retro off).
- Walk through scenarios A–F from design transcript; outputs match.
- Hold caps, type "abc" → "ABC" (no — wait, ctrl-a-b-c, app-specific).
- Type "the " quickly → "the " (rolling press not falsely held — but
  with permissive_hold on, this depends on timing; document the trade-off).
- Auto-repeat: tap caps quickly twice → "esc esc" (or whatever escape
  triggers); then hold third press → ctrl held.

**Files added:** `TapHoldMachine.zig`. **Files modified:** `Parser.zig`,
`Hotkey.zig`, `Hidutil.zig`, `EventTap.zig`, `Mappings.zig`.

---

## Phase 4 — `hold:` as momentary layer

**Goal:** complete the first goal — built-in space → fn_layer.

**Deliverables:**

- Parser resolves `hold: <name>` against the mode table at parse-end. If
  `<name>` is a declared mode → momentary-layer semantics. Else → key or
  modifier (Phase 3 path).
- `TapHoldMachine` extension: on hold-commit for a layer rule, push
  capture-mode entry. On layer-key release, pop the mode + scrub
  in-flight translations.
- `src/TranslationTracker.zig` — `HashMap<keycode, translated_keycode>`.
  When a layer hotkey forwards (`fn_layer < j | down`), record
  `j → down`. On the original key's keyup (regardless of current mode),
  look up + emit the translated keyup; remove entry. Bounded size,
  pre-allocated.
- Mode-entry command (`:: fn_layer @ : @anybar_color("green")`) fires on
  hold-commit. Mode-exit command (`:: default : @anybar_color("hollow")`)
  fires on key release.

**Test surface:**

- Drop `taphold_test.skhdrc` (will be renamed by then) into the user's
  config slot. Type with built-in keyboard, compare to convolution QMK.
  Should feel identical.
- Specific scenarios:
  - Hold space + j → down arrow.
  - Hold space + j + release space while j held → down arrow stops on
    j-release (translation tracking).
  - Hold space alone past timeout, release → space character emitted
    (retro_tap on for this rule).
  - AnyBar indicator changes on layer entry/exit.

**Files added:** `TranslationTracker.zig`. **Files modified:**
`TapHoldMachine.zig`, `Mode.zig`, `Parser.zig`.

---

## Phase 5 — Polish

- `--list-devices` formatting; include transport (USB/Bluetooth) and
  whether each device is currently in use by any rule.
- First-launch UX: clear stderr message when Input Monitoring permission
  is denied (parallel to existing Accessibility flow).
- README/CLAUDE.md updates documenting the new DSL surface.
- Replace `taphold_test.skhdrc` → `remap_test.skhdrc` (or fold into a
  proper testdata fixture).

---

## Out of scope for v1 (deferred)

- `flow_tap` — auto-tap during fast typing. Adds preceding-key tracking.
- `chordal_hold` — opposite-hands rule. Requires per-key handedness map.
- `mod_neutralizer` — defensive keycode between mod-down/up during
  retro-tap to avoid app-level lone-mod handlers.
- Predicate matching on `.device` (e.g.,
  `[device:vendor=0x4FE]`). Currently exact-alias only.
- Per-device gating on layer keys (`fn_layer < h [device:builtin] | left`).
  Currently layer keys are device-agnostic once layer is active.
- Mouse event monitoring for tap-hold interruption.
