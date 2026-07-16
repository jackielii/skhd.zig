# Hotkey Sequences Design

> Revised 2026-07-16. The data model changed: sequences are no longer a
> separate type. See "Data Model" and "Revision Note".

## Goal

Add application-aware, comma-separated hotkey sequences without moving ordinary hotkey behavior into `skhd-grabber` or introducing hidden modes.

The motivating request (issue: "cmd - q closes any other app but cmd - qq is required to close app XYZ") is a safety binding that requires two `cmd-q` chords within a short interval before quitting a chosen application, while every other application keeps the ordinary macOS Quit:

```skhd
cmd - q, cmd - q [ "XYZ" : quit-command ]
```

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
wildcard_command: ?ProcessCommand = null,
mappings: std.StringArrayHashMapUnmanaged(ProcessCommand) = .empty,
mode_list: std.AutoArrayHashMapUnmanaged(*Mode, void) = .empty,

pub fn isSequence(self: *const Hotkey) bool {
    return self.chords.len > 1;
}
```

`flags` and `key` are removed; every reader uses `chords[0].flags` / `chords[0].key`. `Hotkey.create` takes the chords and dupes them, making `len >= 1` structural rather than a convention. `destroy` frees them.

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

### The uniqueness rule

Within a mode, two hotkeys conflict **iff** one's chord list is a prefix of the other's **and** their process scopes overlap.

```zig
if (Hotkey.onePrefixesOther(existing, hotkey) and
    Hotkey.processScopesOverlap(existing, hotkey))
{
    return if (existing.chords.len == hotkey.chords.len)
        error.DuplicateHotkeyInMode
    else
        error.AmbiguousSequencePrefix;
}
```

Two error names survive for message quality; there is one rule behind them. Chords compare with **overlap** semantics — either could match the same physical press — which is the old `triggersOverlap` generalized over a list:

```zig
fn chordsOverlap(x: KeyPress, y: KeyPress) bool {
    return x.key == y.key and
        (hotkeyFlagsMatch(x.flags, y.flags) or hotkeyFlagsMatch(y.flags, x.flags));
}
```

This rule exists to guarantee a property the runtime depends on:

> **For any (mode, chord prefix, process), at most one hotkey matches.**

Probe order in an `ArrayHashMap` is Robin Hood order, not config order. Without this guarantee, which hotkey a lookup returns would be arbitrary. With it, probe order cannot be observed.

Consequences, in each direction:

```skhd
# ERROR — identical chords, both wildcard-scoped, scopes overlap
cmd - a : echo first
cmd - a : echo second

# ERROR — cmd-q in Terminal would match both
cmd - q          [ "Terminal" : echo now ]
cmd - q, cmd - q [ "Terminal" : echo later ]

# OK — disjoint apps; each press has exactly one answer
cmd - q          [ "Terminal" : echo t ]
cmd - q, cmd - q [ "XYZ"      : quit-command ]

# OK — shared incomplete prefix, disambiguated by the second chord
cmd - k, cmd - c : comment-command
cmd - k, cmd - u : uncomment-command
```

A bare hotkey (no process list) is stored with a wildcard process scope, and `processScopesOverlap` returns true whenever either side is wildcard. Every existing duplicate-detection case is therefore still an error, and no configuration that parses today changes meaning.

The rule is strictly more permissive in exactly one situation: two separately-declared hotkeys with identical chords and disjoint *explicit* process lists, which errors today and would now parse. This is not a practical concern — that intent is written as one hotkey with one process list, which marshals into a single `Hotkey` with two entries in `mappings` and never reaches the conflict check. Uniqueness still holds if someone writes the split form anyway, since the two can never both apply.

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
- all existing action forms,
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
