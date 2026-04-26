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

## Phase 2 — `.remap` colon form (plain HID remap) ✓

**Status:** landed. Syntax: `.remap <src_key> [device <alias>] : <dst_key>`.
Device guard is required (global remaps are not supported in v1; they would
clobber every connected keyboard).

**What landed:**

- `src/HidKeyMap.zig` — small static map from skhd keysym names
  ("caps_lock", "lctrl", "f18", …) to HID Keyboard/Keypad usage codes
  (page 0x07). `fullUsage(usage)` packs the 64-bit value `hidutil`
  expects.
- `src/Hidutil.zig` — per-device apply/restore via `hidutil property
  --matching '{"VendorID":…,"ProductID":…}' --set '{"UserKeyMapping":…}'`.
  Crash-recovery state file at `~/.cache/skhd/hidutil_state.json` lists
  the (vendor, product) pairs we touched + our pid; `recoverFromCrash()`
  consults this on startup and clears any orphaned mappings before
  reapplying. `restoreAll()` runs from `deinit` and from SIGINT / SIGTERM
  / SIGHUP handlers so a `kill <pid>` or `launchctl stop` leaves the
  user's keyboard in default state.
- `src/Mappings.zig` — `remaps: ArrayListUnmanaged(RemapDecl)` registry
  with `add_remap` conflict detection (same source key on the same
  device → `error.RemapConflict`).
- `src/Parser.zig` — `parse_remap_decl` for the colon form. Source can
  be any keysym (literal/modifier/identifier/single-char) the
  `HidKeyMap` table recognises; destination comes from the
  command-grabbing colon's text. Required device guard mirrors the
  hotkey-side `[device <alias>]` syntax.
- `src/skhd.zig` — lazy Hidutil init when remaps exist; SIGTERM/SIGHUP
  handlers added (SIGINT was already wired) so all three graceful-
  shutdown signals path through `Hidutil.restoreAll()`.

**V1 caveat:** `Hidutil` does not preserve any pre-existing
`UserKeyMapping`. If another tool (Hyperkey, Karabiner-with-driver,
manual `hidutil` invocations) has already set one, applying our remaps
overwrites it; restoring sets it to empty. Document this and detect-and-
warn deferred to Phase 5 polish.

---

## Phase 3 — `.remap` block form, state machine ✓

**Status:** landed. The headline feature — tap-hold dual-function keys.

Config:

```
.remap caps_lock [device builtin] {
    tap : escape
    hold : lctrl
    timeout : 120ms
    permissive_hold : on
    hold_on_other_key_press : off
    retro_tap : off
}
```

**What landed:**

- `src/TapHoldMachine.zig` — per-rule state machine.
  States: `idle → pending → committed_hold`. Driven by
  `CGEventGetTimestamp(event)` for event timing and `CFRunLoopTimer`
  for timeout fires (one timer per rule, reused via
  `CFRunLoopTimerSetNextFireDate`). All four QMK-aligned knobs plus
  auto-repeat preservation.
- `src/HidKeyMap.zig` extensions — `macVKForHidUsage`,
  `modifierFlagForHidUsage`, `needsProxy`, `PROXY_USAGE`.
- `src/Mappings.zig` — `add_taphold` auto-inserts the F18 proxy
  remap when the source is caps_lock. Helper `effectiveSourceUsage`.
- `src/Tokenizer.zig` — `Token_BeginBlock` / `Token_EndBlock` /
  `Token_Colon` (block_depth-aware so `:` is a separator inside
  `{ … }` and command-grabbing outside). Multi-digit number
  tokenisation for durations. Latent EOF-after-digit bug fixed.
- `src/Parser.zig` — `parse_remap_decl` branches on the post-device-
  guard token. Conflict detection across colon and block forms.
- `src/skhd.zig` — `taphold_machines` registry, `routeTapHold`
  dispatcher (source-key match + pending-machine fan-out for
  other-key buffering). Synthesised events tagged with the existing
  `SKHD_EVENT_MARKER`.

**Caps_lock end-to-end:** parse → `add_taphold` queues the proxy remap →
`Hidutil.applyRemaps` shells out to set `UserKeyMapping` per device →
`TapHoldMachine` listens on `kVK_F18` → state machine emits escape /
ctrl according to timing → SIGINT / SIGTERM / SIGHUP / clean exit
restore the keyboard.

**v1 limits:**

- `hold:` accepts only key/modifier targets in Phase 3. Layer/mode
  holds (`hold: fn_layer`) are Phase 4.
- Multiple simultaneously-pressed tap-hold sources: behaviour is
  "first machine that consumes wins"; not formally modelled.
- Tap-hold processing skipped on the `NX_SYSDEFINED` (media-key)
  path — covers no realistic source key.
- `Hidutil` does not preserve any pre-existing `UserKeyMapping`
  from other tools (Hyperkey etc.).

**Files added:** `TapHoldMachine.zig`. **Files modified:**
`Parser.zig`, `Tokenizer.zig`, `Mappings.zig`, `HidKeyMap.zig`,
`skhd.zig`.

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
