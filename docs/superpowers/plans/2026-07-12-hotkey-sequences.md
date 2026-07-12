# Hotkey Sequences Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add application-aware comma-separated hotkey sequences with a 300ms inter-chord timeout while leaving HID grabber behavior unchanged.

**Architecture:** Add a focused `Sequence.zig` value type and matcher, store sequences per mode beside ordinary hotkeys, and teach the parser to build complete comma-separated chords. The user-session event tap owns one pending match and a one-shot Core Foundation timer; it filters candidates by the frontmost process before consuming a prefix.

**Tech Stack:** Zig 0.16, Core Graphics event taps, Core Foundation run-loop timers, existing `Hotkey`, `Mode`, `Mappings`, and parser infrastructure.

## Global Constraints

- A sequence contains at least two complete chords.
- The maximum interval between matched key-down events is 300ms.
- Each chord carries its own modifiers; modifier presses are independent between steps.
- Failed or expired prefixes are consumed and never replayed.
- Prefix conflicts are rejected only when effective process scopes overlap; wildcard scope overlaps every explicit process.
- No `skhd-grabber` protocol or daemon changes.
- `zig build test` is the authoritative test command.

---

### Task 1: Sequence value, ownership, matching, and scope overlap

**Files:**
- Create: `src/Sequence.zig`
- Modify: `src/Hotkey.zig`
- Modify: `build.zig`

**Interfaces:**
- Consumes: `Hotkey.KeyPress`, `Hotkey.ProcessCommand`, and `Hotkey.hotkeyFlagsMatch`.
- Produces: `Sequence.create(allocator, chords)`, `destroy()`, `matchesStep(index, eventkey)`, `findCommandForProcess(process_name)`, `scopesOverlap(a, b)`, and a timer-independent `Matcher`.

- [ ] **Step 1: Write failing ownership and chord-matching tests in `src/Sequence.zig`**

```zig
test "sequence owns chords and matches complete steps" {
    const chords = [_]Hotkey.KeyPress{
        .{ .flags = .{ .cmd = true }, .key = 0x0C },
        .{ .flags = .{ .cmd = true }, .key = 0x0C },
    };
    var seq = try Sequence.create(std.testing.allocator, &chords);
    defer seq.destroy();
    try std.testing.expect(seq.matchesStep(0, chords[0]));
    try std.testing.expect(!seq.matchesStep(1, .{ .flags = .{}, .key = 0x0C }));
}
```

- [ ] **Step 2: Run the new unit test and verify it fails**

Run: `zig build test`

Expected: FAIL because `Sequence` and its API do not exist.

- [ ] **Step 3: Implement the owned sequence value**

```zig
pub const Sequence = @This();

allocator: std.mem.Allocator,
chords: []Hotkey.KeyPress,
action: *Hotkey,

pub fn create(allocator: std.mem.Allocator, chords: []const Hotkey.KeyPress, action: *Hotkey) !*Sequence {
    if (chords.len < 2) return error.SequenceTooShort;
    const self = try allocator.create(Sequence);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .chords = try allocator.dupe(Hotkey.KeyPress, chords),
        .action = action,
    };
    return self;
}

pub fn destroy(self: *Sequence) void {
    self.allocator.free(self.chords);
    self.action.destroy();
    self.allocator.destroy(self);
}

pub fn matchesStep(self: *const Sequence, index: usize, eventkey: Hotkey.KeyPress) bool {
    if (index >= self.chords.len) return false;
    const chord = self.chords[index];
    return chord.key == eventkey.key and Hotkey.hotkeyFlagsMatch(chord.flags, eventkey.flags);
}
```

- [ ] **Step 4: Expose process-scope inspection without duplicating action lookup**

Add to `Hotkey.zig`:

```zig
pub fn hasWildcardAction(self: *const Hotkey) bool {
    return self.wildcard_command != null;
}

pub fn hasExplicitProcess(self: *const Hotkey, process_name: []const u8) bool {
    var it = self.mappings.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, process_name)) return true;
    }
    return false;
}

pub fn processScopesOverlap(a: *const Hotkey, b: *const Hotkey) bool {
    if (a.hasWildcardAction() or b.hasWildcardAction()) return true;
    var it = a.mappings.iterator();
    while (it.next()) |entry| {
        if (b.hasExplicitProcess(entry.key_ptr.*)) return true;
    }
    return false;
}
```

- [ ] **Step 5: Add timer-independent candidate matching tests and implementation**

Cover start filtering by `find_command_for_process`, shared-prefix narrowing, completion, mismatch, process change, mode change, and timeout via an explicit `cancel()` call. The matcher API must be:

```zig
pub const MatchResult = union(enum) {
    none,
    pending,
    complete: *Sequence,
    mismatch,
};

pub const Matcher = struct {
    candidates: std.ArrayListUnmanaged(*Sequence) = .empty,
    next_index: usize = 0,
    process_name: []const u8 = "",

    pub fn start(self: *Matcher, allocator: std.mem.Allocator, sequences: []const *Sequence, eventkey: Hotkey.KeyPress, process_name: []const u8) !MatchResult;
    pub fn feed(self: *Matcher, eventkey: Hotkey.KeyPress, process_name: []const u8) MatchResult;
    pub fn cancel(self: *Matcher, allocator: std.mem.Allocator) void;
};
```

- [ ] **Step 6: Run tests and commit**

Run: `zig build test`

Expected: PASS.

```bash
git add src/Sequence.zig src/Hotkey.zig build.zig
git commit -m "feat: add hotkey sequence matcher"
```

---

### Task 2: Mode storage, parser grammar, and application-aware conflicts

**Files:**
- Modify: `src/Mode.zig`
- Modify: `src/Mappings.zig`
- Modify: `src/Parser.zig`
- Test: unit tests in the same files

**Interfaces:**
- Consumes: `Sequence.create`, `Sequence.destroy`, `Hotkey.processScopesOverlap`, and existing hotkey action parsing.
- Produces: `Mode.sequences`, `Mode.addSequence(sequence)`, `Mappings.add_sequence(sequence)`, and comma-separated chord parsing.

- [ ] **Step 1: Write parser tests for two- and three-chord declarations**

```zig
test "parse application-scoped hotkey sequence" {
    var mappings = try Mappings.init(std.testing.allocator, std.testing.io);
    defer mappings.deinit();
    var parser = try Parser.init(std.testing.allocator, std.testing.io);
    defer parser.deinit();

    try parser.parse(&mappings,
        \\cmd - q, cmd - q [ "Protected App" : echo quit ]
    );
    const mode = mappings.mode_map.get("default").?;
    try std.testing.expectEqual(@as(usize, 1), mode.sequences.items.len);
    try std.testing.expectEqual(@as(usize, 2), mode.sequences.items[0].chords.len);
}
```

Also add tests for three chords, forwarding, unbound, activation, command references, a trailing comma, and a missing chord.

- [ ] **Step 2: Run tests and verify parser failures**

Run: `zig build test`

Expected: FAIL because commas after a chord are not parsed as sequences.

- [ ] **Step 3: Extract existing chord parsing into `parse_keypress` reuse**

Refactor `parse_hotkey` so the initial trigger and every comma-separated continuation call the existing `parse_keypress()` grammar. Preserve mode-prefix parsing before the first chord and preserve passthrough arrow handling only as an action modifier, not a sequence chord.

Use an inline chord buffer:

```zig
var chords: std.ArrayListUnmanaged(Hotkey.KeyPress) = .empty;
defer chords.deinit(self.allocator);
try chords.append(self.allocator, .{ .flags = hotkey.flags, .key = hotkey.key });
while (self.match(.Token_Comma)) {
    const comma = self.previous();
    const chord = self.parse_keypress() catch |err| {
        self.error_info = try ParseError.fromToken(self.allocator, comma, "Expected complete hotkey chord after ','", self.current_file_path);
        return err;
    };
    try chords.append(self.allocator, chord);
}
```

Parse the action once into the `Hotkey` payload. For `chords.len == 1`, call `mappings.add_hotkey`; otherwise create and add a `Sequence` whose action owns that `Hotkey`.

- [ ] **Step 4: Add mode ownership and conflict validation**

Add `sequences: std.ArrayListUnmanaged(*Sequence) = .empty` to `Mode`, destroy entries in `Mode.deinit`, and implement:

```zig
pub fn addSequence(self: *Mode, sequence: *Sequence) !void {
    for (self.sequences.items) |existing| {
        if (Sequence.onePrefixesOther(existing, sequence) and
            Hotkey.processScopesOverlap(existing.action, sequence.action))
            return error.AmbiguousSequencePrefix;
    }
    var it = self.hotkey_map.iterator();
    while (it.next()) |entry| {
        if (Sequence.chordOverlapsHotkey(sequence.chords[0], entry.key_ptr.*) and
            Hotkey.processScopesOverlap(sequence.action, entry.key_ptr.*))
            return error.AmbiguousSequencePrefix;
    }
    try self.sequences.append(self.allocator, sequence);
}
```

Perform the reciprocal check in `Mode.add_hotkey` so declaration order cannot change validation.

- [ ] **Step 5: Test overlap rules**

Add exact tests showing:

```skhd
# valid: no skhd single binding outside Protected App
cmd - q, cmd - q [ "Protected App" : echo protected ]

# valid: explicit disjoint scopes
cmd - q [ "Terminal" : echo terminal ]
cmd - q, cmd - q [ "Protected App" : echo protected ]

# invalid: same explicit scope
cmd - q [ "Protected App" : echo immediate ]
cmd - q, cmd - q [ "Protected App" : echo protected ]

# invalid: wildcard overlaps explicit scope
cmd - q : echo wildcard
cmd - q, cmd - q [ "Protected App" : echo protected ]
```

- [ ] **Step 6: Run tests and commit**

Run: `zig build test`

Expected: PASS.

```bash
git add src/Mode.zig src/Mappings.zig src/Parser.zig
git commit -m "feat: parse application-aware hotkey sequences"
```

---

### Task 3: Event-tap sequence runtime and timer lifecycle

**Files:**
- Modify: `src/skhd.zig`
- Modify: `src/c.zig` only if the autorepeat event-field constant is absent
- Test: `src/skhd.zig`

**Interfaces:**
- Consumes: `Sequence.Matcher`, `Mode.sequences`, existing `processHotkey`, and `Hotkey.find_command_for_process`.
- Produces: `Skhd.sequence_matcher`, `sequence_timer`, `cancelPendingSequence`, and sequence dispatch before ordinary hotkey lookup.

- [ ] **Step 1: Write runtime tests around a timer-free dispatch helper**

Extract a helper whose time source is represented by explicit start/feed/cancel calls. Test that an applicable first prefix returns `.consumed`, a non-applicable prefix returns `.not_found`, a matching final chord returns the action, a mismatch is reprocessed from root, and a changed process cancels.

- [ ] **Step 2: Run tests and verify they fail**

Run: `zig build test`

Expected: FAIL because `Skhd` has no pending sequence state.

- [ ] **Step 3: Add pending state and one-shot timer ownership**

Add:

```zig
const sequence_interval_ms: u32 = 300;

sequence_matcher: Sequence.Matcher = .{},
sequence_timer: c.CFRunLoopTimerRef = null,

fn cancelPendingSequence(self: *Skhd) void {
    if (self.sequence_timer != null) {
        c.CFRunLoopTimerInvalidate(self.sequence_timer);
        c.CFRelease(self.sequence_timer);
        self.sequence_timer = null;
    }
    self.sequence_matcher.cancel(self.allocator);
}
```

The callback receives `*Skhd`, clears the timer handle safely, and cancels the matcher. `startSequenceTimer` always calls `cancelSequenceTimerOnly` before creating and adding a one-shot timer at `CFAbsoluteTimeGetCurrent() + 0.300`.

- [ ] **Step 4: Dispatch sequences before ordinary hotkeys**

In `handleKeyDown`, after blacklist and self-generated checks, ignore autorepeat as a continuation. When pending, feed the matcher first. On mismatch, cancel and continue into root sequence/ordinary lookup for the same event. When idle, call `Matcher.start` with only `current_mode.sequences`; it must filter candidates through `find_command_for_process(process_name)` before returning `.pending`.

On completion, reuse the existing action execution path by extracting `processMatchedHotkey(hotkey, eventkey, event, process_name, via_wildcard)` from `processHotkey`; do not duplicate command, forward, unbound, or activation switches.

- [ ] **Step 5: Wire cancellation into lifecycle boundaries**

Call `cancelPendingSequence()` before:

- swapping mappings in `reloadConfig`,
- applying an activation that changes `current_mode`,
- handling event-tap disabled notifications,
- deinitializing the event tap and mappings,
- and stopping the run loop.

Process changes cancel during the next key event because `Matcher.feed` compares the captured case-insensitive process name. Timer expiry clears idle state even when no later event arrives.

- [ ] **Step 6: Run tests and commit**

Run: `zig build test`

Expected: PASS.

```bash
git add src/skhd.zig src/c.zig
git commit -m "feat: dispatch timed hotkey sequences"
```

---

### Task 4: Syntax documentation and full verification

**Files:**
- Modify: `SYNTAX.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: completed parser and runtime behavior.
- Produces: user-facing sequence grammar and application-specific double-quit example.

- [ ] **Step 1: Document the grammar and exact semantics**

Add to `SYNTAX.md`:

```text
hotkey_sequence = <keysym> ',' <keysym> (',' <keysym>)*
```

Document the 300ms interval, complete modifiers per chord, process filtering before prefix consumption, cancellation without replay, and application-aware ambiguity errors.

- [ ] **Step 2: Add the motivating README example**

```skhd
# Require two Cmd-Q presses in Protected App. Elsewhere the first
# Cmd-Q has no skhd binding and passes through to macOS normally.
cmd - q, cmd - q [
    "Protected App" : osascript -e 'tell application "Protected App" to quit'
]
```

- [ ] **Step 3: Run focused formatting and full verification**

Run: `zig fmt src/Sequence.zig src/Hotkey.zig src/Mode.zig src/Mappings.zig src/Parser.zig src/skhd.zig src/c.zig`

Expected: exit 0.

Run: `zig build test`

Expected: PASS with no failures or hangs.

- [ ] **Step 4: Inspect the final diff**

Run: `git diff --check`

Expected: no output.

Run: `git status --short`

Expected: only sequence implementation and documentation files are modified; the user's untracked `AGENTS.md` remains untouched.

- [ ] **Step 5: Commit documentation**

```bash
git add SYNTAX.md README.md
git commit -m "docs: document hotkey sequences"
```
