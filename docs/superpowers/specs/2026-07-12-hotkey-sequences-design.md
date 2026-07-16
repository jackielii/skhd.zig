# Hotkey Sequences Design

> Revised 2026-07-16. The data model changed: sequences are no longer a
> separate type. See "Data Model" and "Revision Note".

## Goal

Add application-aware, comma-separated hotkey sequences without moving ordinary hotkey behavior into `skhd-grabber` or introducing hidden modes.

The motivating request (issue: "cmd - q closes any other app but cmd - qq is required to close app XYZ") is a safety binding that requires two `cmd-q` chords within a short interval before quitting a chosen application, while every other application keeps the ordinary macOS Quit:

```skhd
cmd - q, cmd - q [ "XYZ" | cmd - q ]
```

The action is a **forward of the original chord**, so the second press hands a real `cmd-q` to the application and it quits natively — no shell command required. A single press is consumed and dropped 300ms later, which is the safety behavior being asked for. `[ "XYZ" : quit-command ]` works equally well if a command is wanted instead.

In applications with no declared binding, skhd does not match `cmd-q` at all, so it passes through and macOS quits normally. No extra rule is needed to get that.

The grammar supports more than two chords so the same implementation expresses sequences such as:

```skhd
cmd - k, cmd - c : command
```

## Scope

- A sequence is two or more complete hotkey chords separated by commas.
- Each chord carries its own modifiers; modifiers are not inherited from the previous chord.
- The default maximum interval between consecutive chords is 300 milliseconds.
- Sequences support the same actions as existing hotkeys: commands, forwarding, unbound actions, mode activation, command references, and process-specific lists.
- Sequence recognition stays in the user-session event-tap process.
- This change does not add configuration for the interval. A configurable interval can be considered separately if real usage requires it.

The first implementation is not a text-editor-style keymap engine. It does not add arbitrary predicates, alternative steps, simultaneous chords, or replay of failed prefixes.

**Out of scope:** modifier-transparent forwarding (making a rule's declared modifiers a minimum rather than an exact match, so `fn - j | down` also handles `fn+shift-j`). That is a separate feature with its own precedence model, specified separately. It interacts with this design — see "Interaction With Modifier Transparency".

## Architecture

Input continues through the existing layers:

```text
physical keyboard
  -> skhd-grabber HID remap, tap-hold, and layer behavior
  -> virtual HID keyboard
  -> skhd event tap hotkeys, sequences, and application filtering
  -> frontmost application
```

The grabber remains unaware of sequences and applications. It emits the effective keyboard stream after applying HID-level transformations. Sequence matching observes that stream at the event tap, so a remapped key participates using its transformed identity and tap-hold output participates only after the grabber commits it.

No grabber protocol or root-daemon state changes are required.

## Data Model

**A sequence is a hotkey, not a separate type.** `Hotkey` carries its chords directly:

```zig
// Hotkey.zig
allocator: std.mem.Allocator,
/// The chords that must be pressed in order to fire this hotkey.
/// Owned. Invariant: len >= 1. chords[0] is the trigger.
chords: []const KeyPress,
/// `->`: run the action but still deliver the keypress. A property of
/// the binding, not of any one chord. Applies to the final chord only.
passthrough: bool = false,
wildcard_command: ?ProcessCommand = null,
mappings: std.StringArrayHashMapUnmanaged(ProcessCommand) = .empty,
mode_list: std.AutoArrayHashMapUnmanaged(*Mode, void) = .empty,

pub fn isSequence(self: *const Hotkey) bool {
    return self.chords.len > 1;
}
```

`flags` and `key` are removed; every reader uses `chords[0].flags` / `chords[0].key`. `Hotkey.create` takes the chords and dupes them, making `len >= 1` structural rather than a convention. `destroy` frees them.

### Hoisting `passthrough` out of `ModifierFlag`

`passthrough` is currently a bit inside `ModifierFlag` (`Keycodes.zig:38`), set by merging it into `hotkey.flags` (`Parser.zig:308`) and read as `hotkey.flags.passthrough` (`skhd.zig:1431`). It is not a modifier — it is a routing marker, and `ModifierFlag.isEmpty` already has to zero it out to avoid it gating wildcard matching (`Keycodes.zig:68-73`).

This design forces the issue: once `flags` means `chords[0].flags`, a whole-binding property would be stored inside the first chord's modifier set, and `chords[1].flags.passthrough` would be undefined nonsense. So it moves to a `Hotkey` field and leaves `ModifierFlag` a pure modifier set:

- `ModifierFlag.passthrough` is removed; `isEmpty` loses its special case and becomes a plain zero test.
- `Parser` sets `hotkey.passthrough = true` on `->`.
- `skhd.zig` reads `hotkey.passthrough`.

This is a contained cleanup directly forced by the work, not unrelated refactoring.

### Ownership

`Mappings.hotkeys` owns every hotkey, with no exceptions. `Mode.hotkey_map` holds borrowed pointers, exactly as it does today. There is one owner and one destruction path.

This is the point of the revision. The previous model had `Sequence` own its action `*Hotkey` while `Mappings.hotkeys` owned every other hotkey — one type with two owners depending on how it was declared — which forced an ownership-transfer flag through the parser.

These all disappear:

| Removed | Why |
| --- | --- |
| `src/Sequence.zig` | A sequence is a `Hotkey`. |
| `Mappings.sequences`, `Mappings.add_sequence` | `Mappings.hotkeys` / `add_hotkey` cover both. |
| `Mode.sequences`, `Mode.addSequence` | `hotkey_map` holds sequences too. |
| Parser's `hotkey_owned` flag | Only one ownership path exists. |
| `Sequence.Matcher`, its candidate list | Replaced by a chord-prefix buffer. |
| `Hotkey.triggersOverlap`, `Sequence.chordOverlapsHotkey`, `Sequence.onePrefixesOther` | One prefix-overlap predicate. |

### Map keying

`HotkeyMap` continues to hash by the first chord's key code, so hotkeys sharing a key code land in one probe chain and `eql` separates them:

```zig
pub fn hash(_: @This(), key: *Hotkey) u32 { return key.chords[0].key; }
```

`Hotkey.eql` compares chord lists element-wise using the existing `compareLRMod` semantics, and is false when the lengths differ. That lets `cmd - q` and `cmd - q, cmd - q` coexist as distinct entries.

## Parsing and Validation

The comma token already exists. In a hotkey declaration, a comma after the first complete chord starts another complete chord. Parsing continues until the action delimiter (`:`, `|`, `~`, or `;`) or a process list.

```skhd
cmd - q, cmd - q : quit-command
cmd - k, cmd - c [ "Code" : comment-command ]
alt - x, ctrl + shift - y | cmd - z
```

Every step uses the existing modifier and keysym grammar. A missing chord after a comma is a parse error with the comma's source location.

`parse_hotkey` collects modes into a local list and parses all chords **before** constructing the hotkey, then adds the modes and parses the action. This is required by the `len >= 1` invariant — the hotkey cannot exist before its chords are known — and it removes the conditional `errdefer`.

### Grammar coverage

The full existing grammar works on every chord and with every action form. Chords are parsed by `parse_keypress`, which already handles alias-modifiers, alias-keys, `modifier - key`, named keys, hex keycodes, and literals; calling it per chord is what makes each chord carry the complete grammar.

| Form | Example | Notes |
| --- | --- | --- |
| Command | `cmd - k, cmd - c : echo hi` | |
| Forward | `cmd - q, cmd - q \| cmd - q` | See "Forwarding a chord the sequence starts with". |
| Unbound | `cmd - k, cmd - c ~` | Final chord passes through. |
| Mode activation | `cmd - k, cmd - m ; winmode : cmd` | Activation cancels pending state; the prefix is already clear. |
| Passthrough | `cmd - k, cmd - c -> : echo hi` | Final chord only — see below. |
| Process list | `cmd - k, cmd - c [ "Code" : cmd ]` | |
| Process group | `cmd - k, cmd - c [ @native_apps \| end ]` | |
| Command reference | `cmd - k, cmd - c : @name("arg")` | Resolved at parse time; orthogonal. |
| Multi-mode | `winmode, fn_layer < cmd - k, cmd - c : cmd` | No comma ambiguity — see below. |
| Hex / literal / alias chords | `cmd - 0x1B, alt - return` | Per-chord via `parse_keypress`. |

**No comma ambiguity with multi-mode.** `parse_hotkey` enters mode parsing only when the declaration starts with a `Token_Identifier`, and mode parsing consumes its comma-separated list and requires `<`. Chord parsing begins after that. Key tokens (`a`, `1`) lex as `Token_Key`, not `Token_Identifier` (`Tokenizer.zig:361`), so a sequence can never be mistaken for a mode list.

**Passthrough applies to the final chord.** Earlier chords are always consumed: when chord 1 of `cmd - k, cmd - c -> : echo hi` arrives, it is not yet known whether the sequence will complete, so it cannot be delivered. Passing it through and *also* firing on completion would deliver a `cmd-k` the user never meant to send. So `->` (and `~`) affect only the chord that completes the binding. This matters solely for sequences; a one-chord hotkey is its own final chord and behaves exactly as today.

### The uniqueness rule

Within a mode, two hotkeys conflict when one's chord list is a prefix of the other's **and** their process scopes overlap — plus one case the scope gate cannot cover:

```zig
if (!Hotkey.onePrefixesOther(existing, hotkey)) continue;
// HotkeyMap keys on chords alone, so eql-equal hotkeys cannot coexist
// regardless of process scope — put() would silently drop one.
if (Hotkey.eql(existing, hotkey)) return error.DuplicateHotkeyInMode;
if (!Hotkey.processScopesOverlap(existing, hotkey)) continue;
return if (existing.chords.len == hotkey.chords.len)
    error.DuplicateHotkeyInMode
else
    error.AmbiguousSequencePrefix;
```

The identity gate is not a second rule — it is the data structure asserting itself. `HotkeyMap`'s context keys on `Hotkey.eql`, which compares chord lists and ignores process scope. Two hotkeys with *identical* chords are therefore the same key: `put` keeps the first and silently discards the second, whatever their process lists say. Rejecting that config is strictly better than accepting it and dropping a binding the user wrote. So identical chords conflict unconditionally, exactly as they do today.

The gate must sit **before** the scope check or it never runs, and it is reachable precisely because `eql` implies `onePrefixesOther` (equal flags satisfy `hotkeyFlagsMatch` in both directions).

Two error names survive for message quality. Chords compare with **overlap** semantics — some one physical press could match both — resolved **per modifier family**:

```zig
fn chordsOverlap(x: KeyPress, y: KeyPress) bool {
    if (x.key != y.key) return false;
    return familyOverlap(x.flags, y.flags, .alt) and
        familyOverlap(x.flags, y.flags, .cmd) and
        familyOverlap(x.flags, y.flags, .control) and
        familyOverlap(x.flags, y.flags, .shift) and
        x.flags.@"fn" == y.flags.@"fn" and
        x.flags.nx == y.flags.nx;
}
```

Per-family is load-bearing, and it is where the old `triggersOverlap` was wrong. `triggersOverlap` asked `hotkeyFlagsMatch(x, y) or hotkeyFlagsMatch(y, x)` — whole-set, one direction at a time. But which config is the "general" one can differ **per family**, and then neither whole-set direction holds:

```skhd
# Both accepted by the old whole-set predicate; one physical
# lcmd+lshift+x press matches both. cmd needs x-as-config,
# shift needs y-as-config, so no single direction sees it.
cmd + lshift - x : echo A
lcmd + shift - x, cmd - y : echo B
```

`familyOverlap` instead intersects the keyboard states each config accepts for that family, reading the semantics straight off `hotkeyFlagsMatch`: a config's general bit (`cmd`) accepts an event carrying general, left, or right; a specific bit (`lcmd`) accepts exactly that side; an absent family requires the event to lack it entirely. So a general config overlaps any config that names the family at all, two specific configs overlap iff their side bits are equal, and an absent family overlaps only another absent family.

The accepted consequence: configs mixing general and specific modifiers across families in two overlapping rules now error where they previously parsed. They were already nondeterministic — probe order decided which one fired — so this converts a silent coin flip into a config error.

This rule exists to guarantee a property the runtime depends on:

> **For any (mode, chord prefix, process), at most one hotkey matches.**

Probe order in an `ArrayHashMap` is Robin Hood order, not config order. Without this guarantee, which hotkey a lookup returns would be arbitrary. With it, probe order cannot be observed.

Consequences, in each direction:

Note the process-list examples below use the multi-line form. A `:` command lexes to end-of-line, so `[ "Terminal" : echo t ]` on one line swallows the closing `]`. A `|` forward has no such problem — `[ "Terminal" | cmd - q ]` is fine inline.

```skhd
# ERROR — identical chords, both wildcard-scoped
cmd - a : echo first
cmd - a : echo second

# ERROR — identical chords. Disjoint apps do NOT help: HotkeyMap keys on
# chords alone, so the second could only be dropped, never bound.
# Write this as ONE hotkey with a two-entry process list instead.
cmd - a [
    "Terminal" : echo terminal
]
cmd - a [
    "Firefox" : echo firefox
]

# OK — chords overlap but are not identical (alt vs lalt), scopes disjoint.
# Both are stored as distinct keys; the lookup picks by frontmost app.
alt - a [
    "Terminal" : echo terminal
]
lalt - a [
    "Firefox" : echo firefox
]

# ERROR — cmd-q in Terminal would match both
cmd - q [
    "Terminal" : echo now
]
cmd - q, cmd - q [
    "Terminal" : echo later
]

# OK — different chord lengths, disjoint apps; each press has one answer
cmd - q [
    "Terminal" : echo t
]
cmd - q, cmd - q [ "XYZ" | cmd - q ]

# OK — shared incomplete prefix, disambiguated by the second chord
cmd - k, cmd - c : comment-command
cmd - k, cmd - u : uncomment-command
```

A bare hotkey (no process list) is stored with a wildcard process scope, and `processScopesOverlap` returns true whenever either side is wildcard. Every existing duplicate-detection case is therefore still an error, and no configuration that parses today changes meaning.

The rule is more permissive than today's in exactly one shape: chords that **overlap without being identical** (`alt - a` vs `lalt - a`) with disjoint explicit process lists. Those are distinct `HotkeyMap` keys, so both are genuinely stored, and `PrefixLookupContext` selects one per frontmost app. Identical chords stay an error however their scopes are written, because the map cannot represent both.

## Runtime Semantics

The pending state is the **chord prefix matched so far** — not a candidate list. Each key-down asks one lookup two questions: is there a hotkey whose chords extend `prefix ++ eventkey`, and is its chord count equal to the prefix length (complete) or greater (pending)? Enumerating candidates is unnecessary: when `cmd-k,cmd-c` and `cmd-k,cmd-u` both extend `[cmd-k]`, either one proves "pending", and the next chord disambiguates.

```zig
pub const PrefixLookupContext = struct {
    /// Frontmost process, or null to match structurally — ignoring
    /// whether the hotkey has an action that applies here. The null
    /// form answers "did any rule claim this chord?", which gates the
    /// capture-mode fallback. See "Explicit rules claim their chord".
    process_name: ?[]const u8,

    pub fn hash(_: @This(), prefix: []const KeyPress) u32 {
        return prefix[0].key;
    }

    pub fn eql(self: @This(), prefix: []const KeyPress, config: *Hotkey, _: usize) bool {
        if (config.chords.len < prefix.len) return false;
        for (prefix, config.chords[0..prefix.len]) |ev, cfg| {
            if (cfg.key != ev.key) return false;
            if (!hotkeyFlagsMatch(cfg.flags, ev.flags)) return false;
        }
        const proc = self.process_name orelse return true;
        return config.find_command_for_process(proc) != null;
    }
};
```

The process check must be **inside** `eql`. Without it, `cmd - q, cmd - q [ "XYZ" ]` would match structurally in every application, so `cmd-q` in Firefox would go pending, consume the press, and silently drop it 300ms later — breaking the core promise that an undeclared application sees its normal Quit. Inside `eql`, a non-applicable hotkey is skipped and probing continues, so a `cmd - q [ "Terminal" ]` entry does not shadow a `cmd - q, cmd - q [ "XYZ" ]` entry while XYZ is frontmost.

`WildcardLookupContext` gains the same process check, and additionally requires `config.chords.len == 1` so the capture-mode fallback cannot fire a sequence hotkey off a single chord.

`PrefixLookupContext` replaces `KeyboardLookupContext` entirely: an ordinary hotkey is the `prefix.len == 1`, `chords.len == 1` case, so there is one lookup path rather than a sequence path bolted beside a hotkey path.

### Explicit rules claim their chord

A rule that names a modifier combination claims it in that mode, whether or not it has an action for the frontmost application. The capture-mode wildcard fallback is consulted only when **no** rule claimed the chord:

```skhd
fn_layer < cmd - h [ "Terminal" : … ]    # claims cmd+h in fn_layer
fn_layer < h | left                      # transparent: h + any modifiers
```

In Firefox, `cmd+h` does **not** become `cmd - left`. The `cmd - h` rule claimed the combination; it simply has nothing to do here, so the capture mode absorbs the key. Only the process-blind (`process_name = null`) query can answer this, because the applicable-hotkey query deliberately skips that rule.

The alternative — falling through to `h | left` — would make the outcome of `cmd+h` depend on the process scoping of a *different* rule, which is not something a reader of the config could predict. Explicitness beats the extra convenience. This preserves today's behavior exactly; it is not a new rule, just one that now needs stating because the applicable-hotkey query no longer enforces it as a side effect.

The precedence this establishes — an explicit rule beats a transparent one — is the same principle a future modifier-transparency feature needs. See "Interaction With Modifier Transparency".

### Forwarding a chord the sequence starts with

```skhd
cmd - q, cmd - q [ "Terminal" | cmd - q ]
```

The event tap is head-inserted at `kCGSessionEventTap` (`EventTap.zig:27`) and `forwardKey` posts to the same tap (`skhd.zig:1152`), so a forwarded event re-enters our own handler. The forward is tagged with `SKHD_EVENT_MARKER` (`skhd.zig:1148`) and `handleKeyDown` returns early on it (`skhd.zig:874-879`).

Two ordering rules make this binding work, and both must be stated rather than left to luck:

1. **The marker check runs before any sequence handling.** Otherwise the forwarded `cmd-q` would re-enter, match its own sequence's first chord, go pending, and be swallowed — the application would never receive the quit, and the binding would silently do nothing.
2. **A self-generated event neither advances nor cancels a pending prefix.** It returns before touching the state. Our own synthesis is not user input and must not participate in matching.

Both hold in the current code by accident of statement order. They become invariants here, with tests.

### Lookup flow

```zig
fn processHotkey(self: *Skhd, eventkey, event, process_name) !HotkeyResult {
    const mode = self.current_mode orelse return .not_found;

    // A sequence cannot begin in one application and finish in another.
    if (self.sequence_prefix_len > 0 and !self.processMatchesCaptured(process_name))
        self.cancelPendingSequence();

    const prefix = self.buildPrefix(eventkey);   // pending prefix ++ eventkey

    if (mode.hotkey_map.getKeyAdapted(prefix, PrefixLookupContext{
        .process_name = process_name,
    })) |hit| {
        if (hit.chords.len > prefix.len) {
            self.commitPrefix(prefix, process_name);   // pending
            self.startSequenceTimer();
            return .consumed;
        }
        self.cancelPendingSequence();
        return self.processMatchedHotkey(hit, eventkey, event, process_name, false);
    }

    // Mismatch mid-sequence: drop the pending prefix and reprocess this
    // chord from the root, so it can still trigger an unrelated hotkey
    // or start a different sequence. Recurses at most once, since the
    // prefix is empty on the retry.
    if (self.sequence_prefix_len > 0) {
        self.cancelPendingSequence();
        return self.processHotkey(eventkey, event, process_name);
    }

    // No applicable hotkey. Consult the transparent fallback only if no
    // rule claimed this chord at all.
    if (mode.capture) {
        const claimed = mode.hotkey_map.getKeyAdapted(prefix, PrefixLookupContext{
            .process_name = null,
        }) != null;
        if (!claimed) {
            if (self.findWildcardHotkey(mode, eventkey, process_name)) |hit|
                return self.processMatchedHotkey(hit, eventkey, event, process_name, true);
        }
    }
    return .not_found;
}
```

Auto-repeat key-downs are suppressed as sequence steps while a prefix is pending.

The process-blind query runs only on the capture-mode miss path, never on the path a matched hotkey takes, so it costs nothing in the common case.

Process changes are detected at the next chord rather than proactively: if the user switches apps and presses nothing, the 300ms timer clears the prefix anyway, so an app-switch callback would be redundant.

Modifier transitions are not sequence steps. Each configured chord is checked from the modifier flags on its key-down event. A sequence may therefore release and press modifiers between steps when its written chords permit it. `cmd - q, cmd - q` requires `cmd` on both `q` events but does not require proof that the same physical modifier press stayed down.

The recognized prefix is never replayed. On timeout or cancellation its consumed key events stay consumed. This is essential for safety bindings such as `cmd-q`, where delayed replay could quit an application unexpectedly.

### Runtime state

```zig
// Skhd
/// Chords matched so far. Allocated once at config load with
/// len == mappings.max_chords, so a sequence can never out-run it.
sequence_prefix: []Hotkey.KeyPress,
sequence_prefix_len: usize = 0,
/// Frontmost process captured at the first chord. find_command_for_process
/// already caps names at 256 bytes, so this matches.
sequence_process: [256]u8 = undefined,
sequence_process_len: usize = 0,
sequence_timer: c.CFRunLoopTimerRef = null,
```

`Mappings.max_chords` is maintained by `add_hotkey` as `@max(max_chords, hotkey.chords.len)`. The buffer is allocated when mappings are built and freed on reload, so **the event loop performs no allocations** — preserving the documented invariant, which the candidate-list matcher broke by duping the process name on every sequence start.

`buildPrefix` writes the incoming chord at `sequence_prefix[sequence_prefix_len]`, which is in bounds because a prefix only stays pending when `hit.chords.len > prefix.len`. That makes a pending `sequence_prefix_len` strictly less than the longest configured chord list, hence strictly less than `max_chords`. A prefix that reaches `max_chords` is by definition complete, and the state is cleared before the next chord arrives.

The captured process name is compared against the frontmost app at each later chord. A sequence cannot begin in one application and execute against another.

## Cancellation and Lifecycle

Pending state is cleared when:

- 300ms elapses after the latest matched chord,
- the next non-modifier chord does not match (then reprocessed from the root),
- the frontmost process changes,
- the active mode changes,
- configuration is reloaded,
- the event tap is disabled or torn down,
- or skhd shuts down.

Cancellation is idempotent and always invalidates and releases the run-loop timer before dropping borrowed references to mappings or modes. Reload cancels before swapping mappings, since `sequence_prefix` is sized from the outgoing config.

## Timing

Use a one-shot `CFRunLoopTimer`, following the ownership and invalidation pattern already proven by grabber tap-hold timers. The sequence implementation has its own timer and state machine because it runs in the user agent and operates on application-aware chords rather than HID usages.

The interval is measured between matched key-down events. Completing a chord restarts the timer for the next chord. Timer expiry only clears pending state; it never executes or replays an action.

## Interaction With Modifier Transparency

Modifier-transparent forwarding (out of scope here) would make a rule's declared modifiers a minimum, so `fn - j | down` also matches `fn+shift-j` and merges the extra modifier into the target. That makes `fn - j` and `fn + shift - j` overlap, requiring most-specific-wins precedence — which contradicts the "at most one hotkey matches" invariant this design relies on to make probe order unobservable.

That spec must therefore either restate the invariant as "exactly one *most specific* match" and replace `getKeyAdapted` with a ranked scan, or confine transparency to a fallback tier that is consulted only after an exact lookup misses (which is how capture-mode wildcards already work, and which "Explicit rules claim their chord" now states as a rule). This design does not prejudge that choice; it only records that the invariant is load-bearing and cannot be silently weakened.

The precedence half of that question is already answered here, and the answer should carry over: an explicitly written rule claims its combination, and transparency never overrides it. Whatever makes `fn - j | down` also handle `fn+shift-j` must leave an explicit `fn + shift - j` rule — or an explicit `fn_layer < cmd - h` — in charge of the combination it names.

**This design introduces no behavior change.** Every configuration that parses today keeps its current meaning, including the capture-mode fallback gate.

## Error Handling

- Invalid or ambiguous declarations fail during parsing, identifying the conflicting hotkey and mode.
- Timer allocation failure cancels the new prefix and logs an error; it must not let the consumed prefix through later.
- Command execution and forwarding errors use the existing hotkey action paths.
- Hot reload cancels pending state before swapping mappings, preventing references into freed configuration.

## Testing

Parser and mapping tests cover:

- two- and three-chord parsing,
- complete modifiers on every chord,
- every action form in the grammar-coverage table, including multi-mode declarations with sequence chords and per-chord hex/literal/alias forms,
- process-specific sequence actions,
- malformed commas and missing chords,
- the uniqueness rule in each direction: identical chords with overlapping scopes, prefix conflicts with overlapping scopes, valid prefix reuse across disjoint explicit scopes, wildcard scopes conflicting with explicit scopes,
- and valid shared incomplete prefixes.

Hotkey tests cover the `len >= 1` invariant, chord-list `eql`, and the prefix-overlap predicate.

Lookup tests cover, without a timer:

- complete versus pending resolution by chord count,
- shared prefixes resolving on the second chord,
- a non-applicable process being skipped during probing so a longer sequence is reachable,
- no applicable sequence letting the first chord pass through,
- mismatch reprocessing from the root,
- auto-repeat suppression,
- and process and mode changes.

Re-entrancy tests pin the forward-your-own-trigger binding:

- `cmd - q, cmd - q [ "Terminal" | cmd - q ]` delivers exactly one `cmd-q` to the application on the second press, and the forwarded event does not restart the sequence,
- a self-generated event arriving while a prefix is pending leaves the prefix untouched — neither advanced nor cancelled,
- and a single press followed by the timeout delivers nothing.

Passthrough tests cover `->` on a sequence firing the action while delivering only the final chord, and the existing one-chord passthrough tests must pass unchanged after the flag moves off `ModifierFlag`.

Capture-mode fallback tests pin the claim gate, which is the part most at risk of silent regression:

- an explicit rule with no action for the frontmost app still blocks the fallback (`fn_layer < cmd - h [ "Terminal" ]` plus `fn_layer < h | left` leaves `cmd+h` absorbed in Firefox, not forwarded as `cmd - left`),
- with no rule claiming the chord, the fallback forwards and merges modifiers (`cmd+h` becomes `cmd - left`),
- and an exact-modifier rule that *does* apply takes precedence over the fallback.

Event-tap integration tests cover consuming prefixes, executing only after completion, ordinary hotkey behavior remaining immediate, and cancellation during hot reload.

Existing duplicate-detection tests must pass unchanged — they are the evidence that the uniqueness rule generalizes rather than relaxes today's behavior.

`zig build test` remains the completion gate.

## Documentation

Update `SYNTAX.md` with the comma-separated chord grammar, the 300ms default interval, the uniqueness rule, and cancellation behavior. Add a concise README example centered on the double-`cmd-q` safety use case.

## Revision Note

The 2026-07-12 draft introduced a `Sequence` type owning `chords` and an action `*Hotkey`. That split ownership of `Hotkey` between `Mappings.hotkeys` and `Sequence`, forced an ownership-transfer flag through the parser, gave `Mode` two collections that had to cross-check each other, and duplicated the trigger-overlap predicate three ways. It also broke the allocation-free event loop and rescanned every sequence in the mode on every key-down.

Folding chords into `Hotkey` removes all of it. The behavioral design — the 300ms interval, no replay, application capture, cancellation triggers — is unchanged from that draft. What changed is the type, the ownership, the conflict rule (now one predicate over chord lists, gated on process scope), and the lookup (now one prefix-adapted context serving both ordinary hotkeys and sequences).
