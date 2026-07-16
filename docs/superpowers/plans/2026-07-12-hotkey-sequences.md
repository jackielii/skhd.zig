# Hotkey Sequences Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Support comma-separated hotkey sequences (`cmd - q, cmd - q [ "Terminal" | cmd - q ]`) by folding chords into `Hotkey`, so a sequence *is* a hotkey rather than a separate type.

**Architecture:** `Hotkey.chords: []const KeyPress` replaces `flags`/`key`. `Mappings.hotkeys` owns every hotkey; `Mode.hotkey_map` holds them all, sequences included. A prefix-adapted lookup context answers "complete or pending" from one `getKeyAdapted` call, which is sound because a config-time uniqueness rule guarantees at most one hotkey matches any (mode, prefix, process). Pending state is a chord-prefix buffer sized from the config at load, keeping the event loop allocation-free.

**Tech Stack:** Zig 0.16.0, macOS Core Graphics event taps, Carbon (app switching), CFRunLoopTimer.

**Spec:** `docs/superpowers/specs/2026-07-12-hotkey-sequences-design.md` — read it before starting. This plan implements it; where they disagree, the spec wins.

## Global Constraints

- Zig 0.16.0. Build/test with `zig build test` (single-file `zig test` does not work — module tests need `build_options`/`grabber_protocol`/`plist` imports). Use `ZIG_PROGRESS=0 zig build test` if it hangs.
- `zig build test` exits 0 at baseline. Its output already contains two `failed command: ./.zig-cache/o/.../test …` lines, benchmark timings, and two `[hidutil] (warn):` lines — pre-existing Zig 0.16 noise from steps that write to stderr. **Judge by exit code.**
- **`zig build bench` is broken independently of this work and is NOT a gate.** It fails identically at the merge-base with `main`: `src/benchmark.zig:9` uses `std.heap.GeneralPurposeAllocator`, removed in Zig 0.16 (there is also a stale `Skhd.init` signature). Do not fix it here — out of scope. Consequence to be aware of: `build.zig:423` wires `src/benchmark.zig` into the `bench` step only, so `zig build test` never compiles it and **changes to that file are not compiler-verified**. Migrate it by hand and by inspection.
- `zig build` (the main binary) must succeed. That is the real compile gate.
- The event loop must perform **zero allocations** in release builds. No `dupe`/`append` on any key-down path.
- Every existing test must pass unchanged unless a task explicitly says otherwise. The existing duplicate-detection tests are the evidence that the uniqueness rule generalizes rather than relaxes current behavior.
- No configuration that parses today may change meaning.
- Unexported by default: helpers not used across modules stay private.
- Commit after every task. Never commit with failing tests.

## Starting State

Branch `codex/hotkey-sequences` has a **working but superseded** implementation: `src/Sequence.zig` defines a `Sequence` type that owns its action `*Hotkey`, `Mode`/`Mappings` each keep a parallel `sequences` list, and `skhd.zig` drives a `Sequence.Matcher` with a candidate list. This plan migrates that to the chords-on-Hotkey model and deletes `Sequence.zig`.

Do **not** start by deleting things. Tasks 1–3 prepare; Task 4 is the atomic flip.

## File Structure

| File | Responsibility after this plan |
| --- | --- |
| `src/Keycodes.zig` | `ModifierFlag` becomes a pure modifier set — `passthrough` bit removed. |
| `src/Hotkey.zig` | Owns `chords`, `passthrough`, `isSequence`, chord-list `eql`, `onePrefixesOther`, `PrefixLookupContext`, `WildcardLookupContext`. |
| `src/Mode.zig` | `hotkey_map` holds every hotkey; enforces the uniqueness rule. `sequences`/`addSequence` deleted. |
| `src/Mappings.zig` | Sole owner of hotkeys; tracks `max_chords`. `sequences`/`add_sequence` deleted. |
| `src/Parser.zig` | Parses chords before constructing the hotkey; one ownership path. |
| `src/skhd.zig` | Prefix-buffer runtime, prefix lookup, claim gate, timer. |
| `src/Sequence.zig` | **Deleted.** |
| `src/synthesize.zig`, `src/benchmark.zig`, `src/tests.zig` | Migrated to `chords[0]`. |

---

### Task 1: Hoist `passthrough` off `ModifierFlag`

`passthrough` is a routing marker living in a modifier bitfield. `ModifierFlag.isEmpty` already has to zero it out so it doesn't gate wildcard matching. Task 2 makes this untenable — once `flags` means `chords[0].flags`, a whole-binding property would sit inside chord 0's modifier set. Move it first, while it's a small isolated change.

`ModifierFlag` is `packed struct(u32)`; removing the bit shifts `nx` from bit 14 to 13. Verified safe: `ModifierFlag` never crosses the grabber IPC boundary (absent from `grabber_protocol.zig`) and the only `@bitCast`es (`merge`, `isEmpty`) are layout-agnostic.

**Files:**
- Modify: `src/Keycodes.zig:38` (remove field), `src/Keycodes.zig:63-73` (`isEmpty`)
- Modify: `src/Hotkey.zig` (add field), `src/Parser.zig:308`, `src/skhd.zig:1431`
- Test: `src/Parser.zig:2951`, `src/tests.zig:1320`

**Interfaces:**
- Produces: `Hotkey.passthrough: bool = false`. `ModifierFlag` no longer has a `passthrough` field.

- [ ] **Step 1: Update the two tests that read the flag**

`src/tests.zig:1320` — change:
```zig
    try testing.expect(hotkey.flags.passthrough);
```
to:
```zig
    try testing.expect(hotkey.passthrough);
```

`src/Parser.zig:2951` — change:
```zig
            try std.testing.expect(hk.flags.passthrough);
```
to:
```zig
            try std.testing.expect(hk.passthrough);
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: compile error — `no field named 'passthrough' in struct 'Hotkey'`.

- [ ] **Step 3: Add the field to Hotkey**

In `src/Hotkey.zig`, after the `key` field declaration:
```zig
/// `->`: run the action but still deliver the keypress. A property of
/// the binding, not of any one chord — Task 2 makes `flags` per-chord,
/// and passthrough must not live inside chord 0's modifier set.
passthrough: bool = false,
```

- [ ] **Step 4: Remove the bit from ModifierFlag and simplify isEmpty**

In `src/Keycodes.zig`, delete the `passthrough: bool = false,` line (`:38`) and widen the padding from `_: u17 = 0` to `_: u18 = 0`.

Replace `isEmpty` (`:63-73`) with:
```zig
    /// True when no modifier bits are set. Used by capture-mode layer
    /// lookup: a forward rule with no declared modifiers acts as a
    /// "transparent" wildcard.
    pub fn isEmpty(self: ModifierFlag) bool {
        const m: u32 = @bitCast(self);
        return m == 0;
    }
```

- [ ] **Step 5: Update the writer and reader**

`src/Parser.zig:308` — change:
```zig
        hotkey.flags = hotkey.flags.merge(.{ .passthrough = true });
```
to:
```zig
        hotkey.passthrough = true;
```

`src/skhd.zig:1431` — change `hotkey.flags.passthrough` to `hotkey.passthrough`.

- [ ] **Step 6: Run tests**

Run: `zig build test`
Expected: PASS. If any site still references `ModifierFlag.passthrough`, the compiler names it — fix and re-run.

- [ ] **Step 7: Commit**

```bash
git add src/Keycodes.zig src/Hotkey.zig src/Parser.zig src/skhd.zig src/tests.zig
git commit -m "refactor: move passthrough from ModifierFlag to Hotkey

passthrough is a routing marker, not a modifier: isEmpty had to zero it
out to stop it gating wildcard matching. Folding chords into Hotkey makes
flags per-chord, where a whole-binding property cannot live."
```

---

### Task 2: `Hotkey` carries chords

Replace `flags`/`key` with an owned `chords` slice. This is a wide mechanical migration (~90 sites, mostly tests). **Strategy: delete the fields first and let the compiler enumerate every site.** Do not hunt them by grep.

`Sequence.zig` still exists after this task and keeps working — it uses `Hotkey.KeyPress` and `hotkey.flags`/`hotkey.key`, which become `hotkey.chords[0]`. Task 4 deletes it.

**Files:**
- Modify: `src/Hotkey.zig` (fields, `create`, `destroy`, `eql`, `HotkeyMap.hash`, `format`, contexts, `triggersOverlap`)
- Modify: `src/Sequence.zig`, `src/Parser.zig`, `src/skhd.zig`, `src/synthesize.zig`, `src/benchmark.zig`, `src/tests.zig`

**Interfaces:**
- Consumes: `Hotkey.passthrough` (Task 1).
- Produces:
  - `chords: []const KeyPress` — owned, invariant `len >= 1`
  - `Hotkey.create(allocator: std.mem.Allocator, chords: []const KeyPress) !*Hotkey`
  - `Hotkey.isSequence(self: *const Hotkey) bool`

- [ ] **Step 1: Write the failing tests**

Add to `src/Hotkey.zig`:
```zig
test "create dupes chords and reports sequence-ness" {
    const alloc = std.testing.allocator;
    const chords = [_]KeyPress{
        .{ .flags = .{ .cmd = true }, .key = 0x28 },
        .{ .flags = .{ .cmd = true }, .key = 0x08 },
    };
    var hotkey = try Hotkey.create(alloc, &chords);
    defer hotkey.destroy();

    try testing.expectEqual(@as(usize, 2), hotkey.chords.len);
    try testing.expect(hotkey.isSequence());
    try testing.expectEqual(@as(u32, 0x08), hotkey.chords[1].key);
    // Owned, not borrowed.
    try testing.expect(hotkey.chords.ptr != &chords);
}

test "single chord hotkey is not a sequence" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc, &.{.{ .flags = .{ .alt = true }, .key = 0x02 }});
    defer hotkey.destroy();
    try testing.expect(!hotkey.isSequence());
    try testing.expectEqual(@as(u32, 0x02), hotkey.chords[0].key);
}

test "eql compares whole chord lists" {
    const alloc = std.testing.allocator;
    const q = KeyPress{ .flags = .{ .cmd = true }, .key = 0x0C };

    var single = try Hotkey.create(alloc, &.{q});
    defer single.destroy();
    var double = try Hotkey.create(alloc, &.{ q, q });
    defer double.destroy();
    var double2 = try Hotkey.create(alloc, &.{ q, q });
    defer double2.destroy();

    // Different lengths are never equal — this is what lets `cmd - q`
    // and `cmd - q, cmd - q` coexist in one HotkeyMap.
    try testing.expect(!Hotkey.eql(single, double));
    try testing.expect(Hotkey.eql(double, double2));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: compile error — `create` takes 1 argument, and `isSequence` does not exist.

- [ ] **Step 3: Change the Hotkey fields and constructor**

In `src/Hotkey.zig`, move the `KeyPress` declaration above the field block so the field type resolves, then replace the `flags` and `key` field declarations with:
```zig
/// The chords that must be pressed in order to fire this hotkey.
/// Owned. Invariant: len >= 1. chords[0] is the trigger.
chords: []const KeyPress,
```

Replace `create`:
```zig
pub fn create(allocator: std.mem.Allocator, chords: []const KeyPress) !*Hotkey {
    std.debug.assert(chords.len >= 1);
    const hotkey = try allocator.create(Hotkey);
    errdefer allocator.destroy(hotkey);
    hotkey.* = .{
        .allocator = allocator,
        .chords = try allocator.dupe(KeyPress, chords),
    };
    return hotkey;
}
```

In `destroy`, before `self.allocator.destroy(self)`:
```zig
    self.allocator.free(self.chords);
```

Add:
```zig
pub fn isSequence(self: *const Hotkey) bool {
    return self.chords.len > 1;
}
```

- [ ] **Step 4: Update hash, eql, and format**

`HotkeyMap`'s hash function — change `return key.key;` to:
```zig
        // Hash by the first chord's key code only, so hotkeys sharing a
        // trigger land in one probe chain and eql separates them.
        return key.chords[0].key;
```

Replace `eql`:
```zig
pub fn eql(a: *Hotkey, b: *Hotkey) bool {
    if (a.chords.len != b.chords.len) return false;
    for (a.chords, b.chords) |x, y| {
        if (x.key != y.key) return false;
        if (!(compareLRMod(x.flags, y.flags, .alt) and
            compareLRMod(x.flags, y.flags, .cmd) and
            compareLRMod(x.flags, y.flags, .control) and
            compareLRMod(x.flags, y.flags, .shift) and
            x.flags.@"fn" == y.flags.@"fn" and
            x.flags.nx == y.flags.nx)) return false;
    }
    return true;
}
```

In `format`, replace the `flags`/`key` lines with:
```zig
    try writer.writeAll("\n  chords: [");
    for (self.chords, 0..) |chord, i| {
        if (i != 0) try writer.writeAll(", ");
        try writer.print("{f}-{}", .{ chord.flags, chord.key });
    }
    try writer.writeAll("]");
```

- [ ] **Step 5: Update the lookup contexts and triggersOverlap**

These are replaced wholesale in Task 3; this step only keeps the build green.

`KeyboardLookupContext.eql`:
```zig
    pub fn eql(_: @This(), keyboard: Hotkey.KeyPress, config: *Hotkey, _: usize) bool {
        return config.chords[0].key == keyboard.key and
            hotkeyFlagsMatch(config.chords[0].flags, keyboard.flags);
    }
```

`WildcardLookupContext.eql`:
```zig
    pub fn eql(_: @This(), keyboard: Hotkey.KeyPress, config: *Hotkey, _: usize) bool {
        return config.chords[0].key == keyboard.key and config.chords[0].flags.isEmpty();
    }
```

`triggersOverlap`:
```zig
pub fn triggersOverlap(a: *Hotkey, b: *Hotkey) bool {
    if (a.chords[0].key != b.chords[0].key) return false;
    return hotkeyFlagsMatch(a.chords[0].flags, b.chords[0].flags) or
        hotkeyFlagsMatch(b.chords[0].flags, a.chords[0].flags);
}
```

- [ ] **Step 6: Fix every remaining site the compiler names**

Run `zig build test` repeatedly and fix what it reports. The mechanical transformations:

| Before | After |
| --- | --- |
| `hotkey.flags` / `hotkey.key` | `hotkey.chords[0].flags` / `hotkey.chords[0].key` |
| `hk.flags` / `hk.key` | `hk.chords[0].flags` / `hk.chords[0].key` |
| `Hotkey.create(alloc)` then `hotkey.flags = f; hotkey.key = k;` | `Hotkey.create(alloc, &.{.{ .flags = f, .key = k }})` |
| `Hotkey.create(alloc)` with no key set (tests) | `Hotkey.create(alloc, &.{.{ .flags = .{}, .key = 0 }})` |

Specific non-obvious sites:

- `src/Parser.zig:258-296` — `parse_hotkey` constructs the hotkey *before* chords are parsed, which the new `create` signature forbids. Restructure the prologue now: collect modes into a local list, parse all chords, then construct. This is independent of the `Sequence` deletion — the `if (chords.items.len > 1) { … Sequence.create … }` block sits *later* in the function and keeps working off `chords.items` and the constructed `hotkey`, as does `hotkey_owned`. Task 4 deletes that block; this task only moves construction after parsing.

  Change `parse_mode` to collect into a list rather than write to a hotkey that does not exist yet:
  ```zig
  fn parse_mode(self: *Parser, mappings: *Mappings, modes: *std.ArrayListUnmanaged(*Mode)) !void {
  ```
  Inside, replace the `hotkey.add_mode(mode) catch |err| { … }` block with:
  ```zig
      for (modes.items) |existing| {
          if (existing == mode) {
              const msg = try std.fmt.allocPrint(self.allocator, "Mode '{s}' listed twice", .{name});
              defer self.allocator.free(msg);
              self.error_info = try ParseError.fromToken(self.allocator, token, msg, self.current_file_path);
              return error.ParseErrorOccurred;
          }
      }
      try modes.append(self.allocator, mode);
  ```
  and update the recursive call to pass `modes`.

  Then replace `parse_hotkey`'s prologue (lines 258-296) with:
  ```zig
  fn parse_hotkey(self: *Parser, mappings: *Mappings) !void {
      var modes: std.ArrayListUnmanaged(*Mode) = .empty;
      defer modes.deinit(self.allocator);

      if (self.match(.Token_Identifier)) {
          try self.parse_mode(mappings, &modes);
      }

      if (modes.items.len > 0) {
          if (!self.match(.Token_Insert)) {
              const token = self.peek() orelse self.previous();
              self.error_info = try ParseError.fromToken(self.allocator, token, "Expected '<' after mode identifier", self.current_file_path);
              return error.ParseErrorOccurred;
          }
      } else {
          const default_mode = mappings.get_mode_or_create_default("default") catch |err| {
              const msg = try std.fmt.allocPrint(self.allocator, "Failed to get or create default mode: {s}", .{@errorName(err)});
              defer self.allocator.free(msg);
              const token = self.peek() orelse self.previous();
              self.error_info = try ParseError.fromToken(self.allocator, token, msg, self.current_file_path);
              return error.ParseErrorOccurred;
          } orelse unreachable;
          try modes.append(self.allocator, default_mode);
      }

      // Chords are parsed before the hotkey exists: Hotkey.create enforces
      // len >= 1 structurally, so it cannot be constructed empty.
      var chords: std.ArrayListUnmanaged(Hotkey.KeyPress) = .empty;
      defer chords.deinit(self.allocator);
      try chords.append(self.allocator, try self.parse_keypress());
      while (self.match(.Token_Comma)) {
          const comma = self.previous();
          const chord = self.parse_keypress() catch |err| {
              self.clearError();
              self.error_info = try ParseError.fromToken(self.allocator, comma, "Expected complete hotkey chord after ','", self.current_file_path);
              return err;
          };
          try chords.append(self.allocator, chord);
      }

      var hotkey = try Hotkey.create(self.allocator, chords.items);
      var hotkey_owned = true;
      errdefer if (hotkey_owned) hotkey.destroy();
      for (modes.items) |mode| {
          hotkey.add_mode(mode) catch |err| {
              const msg = try std.fmt.allocPrint(self.allocator, "Failed to add mode '{s}' to hotkey: {s}", .{ mode.name, @errorName(err) });
              defer self.allocator.free(msg);
              const token = self.peek() orelse self.previous();
              self.error_info = try ParseError.fromToken(self.allocator, token, msg, self.current_file_path);
              return error.ParseErrorOccurred;
          };
      }
  ```
  Everything below this point in `parse_hotkey` — the arrow/action parsing, the `Sequence.create` block, `mappings.add_hotkey` — is unchanged in this task.
- `src/Parser.zig:364` — `formatKeyPressBuffer(&buf, hotkey.flags, hotkey.key)` → `formatKeyPressBuffer(&buf, hotkey.chords[0].flags, hotkey.chords[0].key)`.
- `src/synthesize.zig:48,51,54,57,59` — all become `hotkey.chords[0].…`.
- `src/benchmark.zig:146` — `HotkeyOriginal.create(allocator)` → `HotkeyOriginal.create(allocator, &.{.{ .flags = .{}, .key = 0x35 }})`.
- `src/Sequence.zig:38-42` — `chordOverlapsHotkey` reads `hotkey.key`/`hotkey.flags` → `hotkey.chords[0].…`.
- `src/Hotkey.zig` test `"hotkey initialization"` asserts `hotkey.key == 0` and bitcast flags — rewrite to assert `chords.len == 1` and inspect `chords[0]`.

- [ ] **Step 7: Run the full suite and the benchmark build**

Run: `zig build test && zig build` (bench is pre-existing broken — see Global Constraints)
Expected: both succeed.

- [ ] **Step 8: Commit**

```bash
git add src/
git commit -m "refactor: Hotkey carries its chords

Replaces flags/key with an owned chords slice (len >= 1). eql compares
whole chord lists and is false on length mismatch, so cmd-q and
cmd-q,cmd-q coexist as distinct HotkeyMap entries. Sequence.zig still
drives matching; the next tasks retire it."
```

---

### Task 3: Uniqueness predicate and prefix lookup context

Add the two pieces Task 4 wires in. Both are new code with unit tests and no runtime callers yet, so this task cannot regress behavior.

**Files:**
- Modify: `src/Hotkey.zig`, `src/Mode.zig` (predicate rename only), `src/skhd.zig` (wildcard ctx signature)

**Interfaces:**
- Consumes: `Hotkey.chords`, `Hotkey.isSequence` (Task 2).
- Produces:
  - `Hotkey.onePrefixesOther(a: *const Hotkey, b: *const Hotkey) bool`
  - `Hotkey.PrefixLookupContext` with field `process_name: ?[]const u8`, used as `map.getKeyAdapted(prefix: []const KeyPress, ctx)`
  - `Hotkey.WildcardLookupContext` with field `process_name: []const u8`

- [ ] **Step 1: Write the failing tests**

Add to `src/Hotkey.zig`:
```zig
test "onePrefixesOther detects prefix relationships with overlap semantics" {
    const alloc = std.testing.allocator;
    const cmd_q = KeyPress{ .flags = .{ .cmd = true }, .key = 0x0C };
    const lcmd_q = KeyPress{ .flags = .{ .lcmd = true }, .key = 0x0C };
    const cmd_a = KeyPress{ .flags = .{ .cmd = true }, .key = 0x00 };

    var single = try Hotkey.create(alloc, &.{cmd_q});
    defer single.destroy();
    var double = try Hotkey.create(alloc, &.{ cmd_q, cmd_q });
    defer double.destroy();
    var other = try Hotkey.create(alloc, &.{cmd_a});
    defer other.destroy();
    var specific = try Hotkey.create(alloc, &.{lcmd_q});
    defer specific.destroy();

    try testing.expect(onePrefixesOther(single, double));
    try testing.expect(onePrefixesOther(double, single));
    try testing.expect(!onePrefixesOther(single, other));
    // Overlap, not equality: a physical lcmd-q press matches both.
    try testing.expect(onePrefixesOther(single, specific));
}

test "prefix lookup resolves complete vs pending and skips inapplicable scopes" {
    const alloc = std.testing.allocator;
    const cmd_q = KeyPress{ .flags = .{ .cmd = true }, .key = 0x0C };

    var immediate = try Hotkey.create(alloc, &.{cmd_q});
    defer immediate.destroy();
    try immediate.add_process_command("Terminal", "echo t");

    var sequence = try Hotkey.create(alloc, &.{ cmd_q, cmd_q });
    defer sequence.destroy();
    try sequence.add_process_command("Protected App", "echo p");

    var map: HotkeyMap = .empty;
    defer map.deinit(alloc);
    try map.put(alloc, immediate, {});
    try map.put(alloc, sequence, {});

    const prefix: []const KeyPress = &.{cmd_q};

    // Terminal: the one-chord rule applies -> complete.
    try testing.expectEqual(immediate, map.getKeyAdapted(prefix, PrefixLookupContext{
        .process_name = "Terminal",
    }).?);

    // Protected App: the one-chord rule is skipped during probing, so the
    // sequence is reachable -> pending (chords.len > prefix.len).
    const in_protected = map.getKeyAdapted(prefix, PrefixLookupContext{
        .process_name = "Protected App",
    }).?;
    try testing.expectEqual(sequence, in_protected);
    try testing.expect(in_protected.chords.len > prefix.len);

    // Firefox: neither applies -> cmd-q passes through to macOS.
    try testing.expect(map.getKeyAdapted(prefix, PrefixLookupContext{
        .process_name = "Firefox",
    }) == null);

    // Process-blind: something claimed the chord, regardless of scope.
    try testing.expect(map.getKeyAdapted(prefix, PrefixLookupContext{
        .process_name = null,
    }) != null);
}

test "prefix lookup narrows a shared prefix on the second chord" {
    const alloc = std.testing.allocator;
    const cmd_k = KeyPress{ .flags = .{ .cmd = true }, .key = 0x28 };
    const cmd_c = KeyPress{ .flags = .{ .cmd = true }, .key = 0x08 };
    const cmd_u = KeyPress{ .flags = .{ .cmd = true }, .key = 0x20 };

    var comment = try Hotkey.create(alloc, &.{ cmd_k, cmd_c });
    defer comment.destroy();
    try comment.add_process_command("*", "comment");
    var uncomment = try Hotkey.create(alloc, &.{ cmd_k, cmd_u });
    defer uncomment.destroy();
    try uncomment.add_process_command("*", "uncomment");

    var map: HotkeyMap = .empty;
    defer map.deinit(alloc);
    try map.put(alloc, comment, {});
    try map.put(alloc, uncomment, {});

    // [cmd-k] matches both; either proves "pending". We don't care which.
    const step1: []const KeyPress = &.{cmd_k};
    const pending = map.getKeyAdapted(step1, PrefixLookupContext{ .process_name = "Code" }).?;
    try testing.expect(pending.chords.len > step1.len);

    // The second chord disambiguates.
    const step2: []const KeyPress = &.{ cmd_k, cmd_u };
    const done = map.getKeyAdapted(step2, PrefixLookupContext{ .process_name = "Code" }).?;
    try testing.expectEqual(uncomment, done);
    try testing.expectEqual(step2.len, done.chords.len);
}

test "wildcard context rejects sequences and inapplicable scopes" {
    const alloc = std.testing.allocator;
    const h = KeyPress{ .flags = .{}, .key = 0x04 };

    var transparent = try Hotkey.create(alloc, &.{h});
    defer transparent.destroy();
    try transparent.add_process_command("*", "left");

    var seq = try Hotkey.create(alloc, &.{ h, h });
    defer seq.destroy();
    try seq.add_process_command("*", "nope");

    var map: HotkeyMap = .empty;
    defer map.deinit(alloc);
    try map.put(alloc, seq, {});
    try map.put(alloc, transparent, {});

    // The fallback must never fire a sequence off a single chord.
    const found = map.getKeyAdapted(
        Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = 0x04 },
        WildcardLookupContext{ .process_name = "Firefox" },
    );
    try testing.expectEqual(transparent, found.?);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: compile error — `onePrefixesOther` and `PrefixLookupContext` are undefined; `WildcardLookupContext` has no `process_name` field.

- [ ] **Step 3: Implement the predicate**

In `src/Hotkey.zig`, replace `triggersOverlap` with:
```zig
/// True when either chord could match the same physical key press.
fn chordsOverlap(x: KeyPress, y: KeyPress) bool {
    return x.key == y.key and
        (hotkeyFlagsMatch(x.flags, y.flags) or hotkeyFlagsMatch(y.flags, x.flags));
}

/// True when one hotkey's chord list is a prefix of the other's (equal
/// length counts). Combined with processScopesOverlap this is the whole
/// conflict rule: it guarantees at most one hotkey matches any
/// (mode, prefix, process), which is what makes probe order in
/// PrefixLookupContext unobservable.
pub fn onePrefixesOther(a: *const Hotkey, b: *const Hotkey) bool {
    const n = @min(a.chords.len, b.chords.len);
    for (a.chords[0..n], b.chords[0..n]) |x, y| {
        if (!chordsOverlap(x, y)) return false;
    }
    return true;
}
```

- [ ] **Step 4: Implement the lookup contexts**

Replace `KeyboardLookupContext` with:
```zig
/// Looks a chord prefix up against a mode's hotkeys.
///
/// The caller reads the result's chord count to decide what happened:
///   chords.len == prefix.len -> complete, fire it
///   chords.len >  prefix.len -> pending, consume and arm the timer
///   null                     -> nothing applicable
///
/// Enumerating candidates is unnecessary: when two sequences share a
/// prefix, either one proves "pending" and the next chord disambiguates.
pub const PrefixLookupContext = struct {
    /// Frontmost process, or null to match structurally — ignoring
    /// whether the hotkey has an action that applies here. The null form
    /// answers "did any rule claim this chord?", which gates the
    /// capture-mode fallback.
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
        // Skipping inapplicable hotkeys during probing is what lets a
        // `cmd - q ["Terminal"]` entry not shadow a
        // `cmd - q, cmd - q ["XYZ"]` entry while XYZ is frontmost.
        const proc = self.process_name orelse return true;
        return config.find_command_for_process(proc) != null;
    }
};
```

Replace `WildcardLookupContext`'s body with:
```zig
pub const WildcardLookupContext = struct {
    process_name: []const u8,

    pub fn hash(_: @This(), key: Hotkey.KeyPress) u32 {
        return key.key;
    }

    pub fn eql(self: @This(), keyboard: Hotkey.KeyPress, config: *Hotkey, _: usize) bool {
        // len == 1: the fallback must never fire a sequence off one chord.
        if (config.chords.len != 1) return false;
        if (config.chords[0].key != keyboard.key) return false;
        if (!config.chords[0].flags.isEmpty()) return false;
        return config.find_command_for_process(self.process_name) != null;
    }
};
```

- [ ] **Step 5: Fix the two callers**

`src/skhd.zig:1356` — thread the process name through:
```zig
pub inline fn findWildcardHotkey(_: *Skhd, mode: *const Mode, eventkey: Hotkey.KeyPress, process_name: []const u8) ?*Hotkey {
    return mode.hotkey_map.getKeyAdapted(eventkey, Hotkey.WildcardLookupContext{
        .process_name = process_name,
    });
}
```
and update its call in `processHotkey` to pass `process_name`.

`src/Mode.zig:71` referenced `triggersOverlap`; point it at the new predicate for now — Task 4 rewrites the rule properly:
```zig
        if (Hotkey.onePrefixesOther(entry.key_ptr.*, hotkey)) {
            return error.DuplicateHotkeyInMode;
        }
```

- [ ] **Step 6: Run tests**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/Hotkey.zig src/Mode.zig src/skhd.zig
git commit -m "feat: add prefix lookup context and uniqueness predicate

onePrefixesOther generalizes triggersOverlap over chord lists.
PrefixLookupContext answers complete-vs-pending from one getKeyAdapted
call; its optional process_name serves both the applicable-hotkey query
and the process-blind claim query. WildcardLookupContext gains the same
process check and rejects sequences. Not wired into the runtime yet."
```

---

### Task 4: The flip — sequences become hotkeys everywhere

The atomic migration. The old and new models cannot coexist, so this task does the whole switch: `Parser` builds sequence hotkeys through `add_hotkey`, `Mode.hotkey_map` holds them, `skhd` drives a prefix buffer, and `Sequence.zig` is deleted.

**Files:**
- Delete: `src/Sequence.zig`
- Modify: `src/Parser.zig` (`parse_hotkey`, `parse_mode`), `src/Mode.zig`, `src/Mappings.zig`, `src/skhd.zig`, `src/tests.zig`

**Interfaces:**
- Consumes: `Hotkey.onePrefixesOther`, `Hotkey.PrefixLookupContext`, `Hotkey.isSequence`.
- Produces:
  - `Mappings.max_chords: usize = 1`
  - `Skhd.sequence_prefix: []Hotkey.KeyPress`, `Skhd.sequence_prefix_len: usize`

- [ ] **Step 1: Write the failing tests**

Replace the three sequence tests the branch added to `src/Parser.zig` (`"parse application-scoped hotkey sequence"`, `"sequence prefix conflicts are scoped by application"`, `"parse three-chord sequence and reject missing chord"`) with:

```zig
test "sequences live in hotkey_map as ordinary hotkeys" {
    const alloc = std.testing.allocator;
    var mappings = try Mappings.init(alloc, std.testing.io);
    defer mappings.deinit();
    var parser = try Parser.init(alloc, std.testing.io);
    defer parser.deinit();

    try parser.parse(&mappings,
        \\cmd - q, cmd - q [
        \\    "Protected App" | cmd - q
        \\]
    );
    const mode = mappings.mode_map.get("default").?;
    try std.testing.expectEqual(@as(usize, 1), mode.hotkey_map.count());

    var it = mode.hotkey_map.iterator();
    const hk = it.next().?.key_ptr.*;
    try std.testing.expect(hk.isSequence());
    try std.testing.expectEqual(@as(usize, 2), hk.chords.len);
    try std.testing.expectEqual(@as(usize, 2), mappings.max_chords);
    // Mappings owns it, like every other hotkey.
    try std.testing.expectEqual(@as(usize, 1), mappings.hotkeys.items.len);
}

test "uniqueness rule gates prefix conflicts on process scope" {
    const alloc = std.testing.allocator;

    // Disjoint scopes: decidable, so allowed.
    {
        var mappings = try Mappings.init(alloc, std.testing.io);
        defer mappings.deinit();
        var parser = try Parser.init(alloc, std.testing.io);
        defer parser.deinit();
        try parser.parse(&mappings,
            \\cmd - q [ "Terminal" : echo terminal ]
            \\cmd - q, cmd - q [ "Protected App" : echo protected ]
        );
    }

    // Overlapping scopes: cmd-q in Terminal would match both.
    {
        var mappings = try Mappings.init(alloc, std.testing.io);
        defer mappings.deinit();
        var parser = try Parser.init(alloc, std.testing.io);
        defer parser.deinit();
        const result = parser.parse(&mappings,
            \\cmd - q [ "Terminal" : echo now ]
            \\cmd - q, cmd - q [ "Terminal" : echo later ]
        );
        try std.testing.expectError(error.ParseErrorOccurred, result);
        try std.testing.expect(std.mem.containsAtLeast(u8, parser.error_info.?.message, 1, "Ambiguous hotkey sequence prefix"));
    }

    // A bare hotkey is wildcard-scoped, so it overlaps every explicit scope.
    {
        var mappings = try Mappings.init(alloc, std.testing.io);
        defer mappings.deinit();
        var parser = try Parser.init(alloc, std.testing.io);
        defer parser.deinit();
        const result = parser.parse(&mappings,
            \\cmd - q : echo immediate
            \\cmd - q, cmd - q [ "Protected App" : echo protected ]
        );
        try std.testing.expectError(error.ParseErrorOccurred, result);
    }
}

test "shared incomplete prefixes are allowed" {
    const alloc = std.testing.allocator;
    var mappings = try Mappings.init(alloc, std.testing.io);
    defer mappings.deinit();
    var parser = try Parser.init(alloc, std.testing.io);
    defer parser.deinit();
    try parser.parse(&mappings,
        \\cmd - k, cmd - c : echo comment
        \\cmd - k, cmd - u : echo uncomment
    );
    try std.testing.expectEqual(@as(usize, 2), mappings.mode_map.get("default").?.hotkey_map.count());
}

test "parse three-chord sequence and reject missing chord" {
    const alloc = std.testing.allocator;
    {
        var mappings = try Mappings.init(alloc, std.testing.io);
        defer mappings.deinit();
        var parser = try Parser.init(alloc, std.testing.io);
        defer parser.deinit();
        try parser.parse(&mappings, "cmd - k, cmd - c, alt - q : echo sequence");
        var it = mappings.mode_map.get("default").?.hotkey_map.iterator();
        try std.testing.expectEqual(@as(usize, 3), it.next().?.key_ptr.*.chords.len);
        try std.testing.expectEqual(@as(usize, 3), mappings.max_chords);
    }
    {
        var mappings = try Mappings.init(alloc, std.testing.io);
        defer mappings.deinit();
        var parser = try Parser.init(alloc, std.testing.io);
        defer parser.deinit();
        try std.testing.expectError(error.ParseErrorOccurred, parser.parse(&mappings, "cmd - q, : echo invalid"));
        try std.testing.expect(std.mem.containsAtLeast(u8, parser.error_info.?.message, 1, "Expected complete hotkey chord"));
    }
}

test "multi-mode declaration with sequence chords" {
    const alloc = std.testing.allocator;
    var mappings = try Mappings.init(alloc, std.testing.io);
    defer mappings.deinit();
    var parser = try Parser.init(alloc, std.testing.io);
    defer parser.deinit();
    // Mode-list commas and chord commas cannot collide: mode lists require
    // '<', and key tokens lex as Token_Key rather than Token_Identifier.
    try parser.parse(&mappings,
        \\:: alpha
        \\:: beta
        \\alpha, beta < cmd - k, cmd - c : echo both
    );
    try std.testing.expectEqual(@as(usize, 1), mappings.mode_map.get("alpha").?.hotkey_map.count());
    try std.testing.expectEqual(@as(usize, 1), mappings.mode_map.get("beta").?.hotkey_map.count());
    // One hotkey, two modes — not two hotkeys.
    try std.testing.expectEqual(@as(usize, 1), mappings.hotkeys.items.len);
}

test "every action form works on a sequence" {
    const alloc = std.testing.allocator;
    var mappings = try Mappings.init(alloc, std.testing.io);
    defer mappings.deinit();
    var parser = try Parser.init(alloc, std.testing.io);
    defer parser.deinit();

    // The spec's grammar-coverage table, in one config: process group,
    // command reference with a placeholder, unbound, mode activation,
    // per-chord hex/literal/alias forms.
    try parser.parse(&mappings,
        \\:: winmode
        \\.define native_apps ["Finder", "Terminal"]
        \\.define notify : echo {{1}}
        \\cmd - k, cmd - c [ @native_apps | end ]
        \\cmd - k, cmd - n : @notify("hi")
        \\cmd - k, cmd - u ~
        \\cmd - k, cmd - m ; winmode : echo entering
        \\cmd - 0x1B, alt - return : echo mixed
    );

    const mode = mappings.mode_map.get("default").?;
    try std.testing.expectEqual(@as(usize, 5), mode.hotkey_map.count());
    try std.testing.expectEqual(@as(usize, 5), mappings.hotkeys.items.len);
    for (mappings.hotkeys.items) |hk| {
        try std.testing.expect(hk.isSequence());
        try std.testing.expectEqual(@as(usize, 2), hk.chords.len);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: FAIL — `mappings.max_chords` does not exist, and `mode.hotkey_map.count()` is 0 for sequences (they still go to `mode.sequences`).

- [ ] **Step 3: Drop the Sequence branch from parse_hotkey**

Task 2 already restructured the prologue (modes into a local list, chords parsed before `Hotkey.create`). This step only removes the `Sequence` detour.

Delete from `src/Parser.zig`:
- the whole `if (chords.items.len > 1) { … Sequence.create … mappings.add_sequence(sequence) … return; }` block,
- the `hotkey_owned` flag, replacing `errdefer if (hotkey_owned) hotkey.destroy();` with plain `errdefer hotkey.destroy();`,
- `const Sequence = @import("Sequence.zig");`.

`parse_hotkey` now ends with the single existing `mappings.add_hotkey(hotkey) catch |err| { … }`, which already has an `AmbiguousSequencePrefix` arm from the branch — keep it. Sequences and one-chord hotkeys travel the same path from here.

- [ ] **Step 4: Apply the uniqueness rule in Mode**

In `src/Mode.zig`, delete the `sequences` field, `addSequence`, `const Sequence = @import("Sequence.zig");`, and the `self.sequences.deinit(self.allocator);` line in `deinit`. Replace `add_hotkey` with:
```zig
pub fn add_hotkey(self: *Mode, hotkey: *Hotkey) !void {
    // Two hotkeys conflict iff one's chord list prefixes the other's AND
    // their process scopes overlap. That guarantees at most one hotkey
    // matches any (mode, prefix, process) — the property PrefixLookupContext
    // relies on to make probe order unobservable.
    //
    // A bare hotkey is wildcard-scoped, so scopes always overlap for it and
    // today's duplicate detection is unchanged.
    var it = self.hotkey_map.iterator();
    while (it.next()) |entry| {
        const existing = entry.key_ptr.*;
        if (!Hotkey.onePrefixesOther(existing, hotkey)) continue;
        if (!Hotkey.processScopesOverlap(existing, hotkey)) continue;
        return if (existing.chords.len == hotkey.chords.len)
            error.DuplicateHotkeyInMode
        else
            error.AmbiguousSequencePrefix;
    }

    try self.hotkey_map.put(self.allocator, hotkey, {});
}
```

- [ ] **Step 5: Track max_chords and drop Mappings.sequences**

In `src/Mappings.zig`: delete the `sequences` field, `add_sequence`, `const Sequence = @import("Sequence.zig");`, and the `for (self.sequences.items) |sequence| sequence.destroy();` / `self.sequences.deinit(self.allocator);` lines in `deinit`. Add the field:
```zig
/// Longest chord list across all hotkeys. Sizes the runtime prefix
/// buffer, so a pending sequence can never out-run it.
max_chords: usize = 1,
```
and maintain it at the end of `add_hotkey`:
```zig
    try self.hotkeys.append(self.allocator, hotkey);
    self.max_chords = @max(self.max_chords, hotkey.chords.len);
```

- [ ] **Step 6: Replace the matcher with a prefix buffer**

In `src/skhd.zig`, delete `const Sequence = @import("Sequence.zig");`, the `SequenceDispatch` union, `dispatchSequence`, the `sequence_matcher` field, and the `"sequence dispatch starts only for an applicable process and completes"` test. Add:
```zig
/// Chords matched so far. Allocated at config load with
/// len == mappings.max_chords. Never allocated on the event loop.
sequence_prefix: []Hotkey.KeyPress = &.{},
sequence_prefix_len: usize = 0,
/// Frontmost process captured at the first chord. find_command_for_process
/// caps names at 256 bytes, so this matches.
sequence_process: [256]u8 = undefined,
sequence_process_len: usize = 0,
```
(keep the existing `sequence_timer` field.)

Add the helpers:
```zig
fn allocSequencePrefix(self: *Skhd) !void {
    self.allocator.free(self.sequence_prefix);
    self.sequence_prefix = try self.allocator.alloc(Hotkey.KeyPress, self.mappings.max_chords);
    self.sequence_prefix_len = 0;
}

/// prefix ++ eventkey. In bounds because a prefix only stays pending when
/// hit.chords.len > prefix.len, so a pending length is strictly less than
/// max_chords; a prefix that reaches max_chords is by definition complete
/// and cleared before the next chord arrives.
fn buildPrefix(self: *Skhd, eventkey: Hotkey.KeyPress) []const Hotkey.KeyPress {
    std.debug.assert(self.sequence_prefix_len < self.sequence_prefix.len);
    self.sequence_prefix[self.sequence_prefix_len] = eventkey;
    return self.sequence_prefix[0 .. self.sequence_prefix_len + 1];
}

fn commitPrefix(self: *Skhd, prefix: []const Hotkey.KeyPress, process_name: []const u8) void {
    self.sequence_prefix_len = prefix.len;
    const n = @min(process_name.len, self.sequence_process.len);
    @memcpy(self.sequence_process[0..n], process_name[0..n]);
    self.sequence_process_len = n;
}

fn processMatchesCaptured(self: *const Skhd, process_name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(self.sequence_process[0..self.sequence_process_len], process_name);
}
```

Rewrite `cancelPendingSequence`:
```zig
fn cancelPendingSequence(self: *Skhd) void {
    self.cancelSequenceTimer();
    self.sequence_prefix_len = 0;
    self.sequence_process_len = 0;
}
```

In `startSequenceTimer`'s failure branch, replace `self.sequence_matcher.cancel(self.allocator)` with `self.cancelPendingSequence()`.

Call `try self.allocSequencePrefix();` in `init` after mappings are parsed, and in `reloadConfig` after the mappings swap (the existing `cancelPendingSequence()` before the swap stays — it must run before the old mappings are freed). Free in `deinit`: `self.allocator.free(self.sequence_prefix);`.

- [ ] **Step 7: Rewrite the lookup flow**

Replace `handleKeyDown`'s sequence block (lines 890-925) with:
```zig
    const eventkey = createEventKey(event);
    if (self.sequence_prefix_len > 0 and
        c.CGEventGetIntegerValueField(event, c.kCGKeyboardEventAutorepeat) != 0)
    {
        return @ptrFromInt(0);
    }

    const result = try self.processHotkey(&eventkey, event, process_name);
    return try self.handleHotkeyResult(result, event, eventkey, process_name);
```

Replace `processHotkey` entirely:
```zig
inline fn processHotkey(self: *Skhd, eventkey: *const Hotkey.KeyPress, event: c.CGEventRef, process_name: []const u8) !HotkeyResult {
    const mode = self.current_mode orelse return .not_found;
    self.tracer.traceHotkeyLookup();

    // A sequence cannot begin in one application and finish in another.
    if (self.sequence_prefix_len > 0 and !self.processMatchesCaptured(process_name))
        self.cancelPendingSequence();

    const prefix = self.buildPrefix(eventkey.*);

    if (mode.hotkey_map.getKeyAdapted(prefix, Hotkey.PrefixLookupContext{
        .process_name = process_name,
    })) |hit| {
        if (hit.chords.len > prefix.len) {
            // Pending: always consumed. `->`/`~` are read only in
            // processMatchedHotkey, i.e. only on the completing chord.
            self.commitPrefix(prefix, process_name);
            self.startSequenceTimer();
            self.tracer.traceHotkeyFound(true);
            return .consumed;
        }
        self.cancelPendingSequence();
        self.tracer.traceHotkeyFound(true);
        return self.processMatchedHotkey(hit, eventkey, event, process_name, false);
    }

    // Mismatch mid-sequence: drop the prefix and reprocess this chord from
    // the root so it can still fire an unrelated hotkey or start another
    // sequence. Recurses at most once — the prefix is empty on retry.
    if (self.sequence_prefix_len > 0) {
        self.cancelPendingSequence();
        return self.processHotkey(eventkey, event, process_name);
    }

    // Capture-mode transparency: consult the fallback only if no rule
    // claimed this chord. An explicit `fn_layer < cmd - h ["Terminal"]`
    // claims cmd+h in that mode, so it must not become `cmd - left` in
    // Firefox merely because that rule has no action there.
    if (mode.capture) {
        const claimed = mode.hotkey_map.getKeyAdapted(prefix, Hotkey.PrefixLookupContext{
            .process_name = null,
        }) != null;
        if (!claimed) {
            if (self.findWildcardHotkey(mode, eventkey.*, process_name)) |hit| {
                self.tracer.traceHotkeyFound(true);
                return self.processMatchedHotkey(hit, eventkey, event, process_name, true);
            }
        }
    }

    self.tracer.traceHotkeyFound(false);
    return .not_found;
}
```

Keep the existing verbose `log.debug("Found hotkey: …")` block by moving it into the completing arm, just before `processMatchedHotkey`. Delete `findHotkeyInMode` if nothing calls it any more.

- [ ] **Step 8: Delete Sequence.zig**

```bash
rm -f src/Sequence.zig
```
Then remove its references: `grep -rn "Sequence" src/ build.zig` and clean up what it reports (the branch added an import in `src/tests.zig`).

- [ ] **Step 9: Run the full suite**

Run: `zig build test && zig build` (bench is pre-existing broken — see Global Constraints)
Expected: PASS, including every pre-existing duplicate-detection test at `src/tests.zig:1055-1190`. Those use bare hotkeys, which are wildcard-scoped, so `processScopesOverlap` returns true and they still error. **If any of them now passes where it used to fail, the uniqueness rule is wired wrong** — most likely `processScopesOverlap` is inverted or the wildcard case is not returning true.

- [ ] **Step 10: Commit**

```bash
git add -A src/
git commit -m "feat: sequences are hotkeys

Parser builds sequence hotkeys through the ordinary add_hotkey path;
Mode.hotkey_map holds them; Mappings.hotkeys is the sole owner. Lookup is
one prefix-adapted getKeyAdapted whose result chord count decides complete
vs pending, and pending state is a chord-prefix buffer sized from the
config at load, so the event loop allocates nothing.

Deletes Sequence.zig, Mappings.sequences, Mode.sequences, the candidate
matcher, and the parser ownership flag."
```

---

### Task 5: Passthrough semantics and re-entrancy invariants

Two behaviors the spec calls out that currently hold only by accident of statement order. Pin them with tests so a later cleanup cannot quietly break them.

**Files:**
- Modify: `src/skhd.zig` (comments + tests)

**Interfaces:**
- Consumes: everything from Task 4.

- [ ] **Step 1: Write the failing tests**

`src/skhd.zig` already has parser-backed runtime tests. **Reuse the existing `createTestSkhdFromConfig(alloc, io, config)` helper** — do not write a new one. Follow the setup in `"processHotkey respects passthrough in capture mode"` (`:1750`) exactly: build `std.Io.Threaded` for `io`, and use a mock event pointer, since `processHotkey` never dereferences it on these paths:

```zig
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const mock_event: c.CGEventRef = @ptrFromInt(0x1234);
```

The `"self-generated events"` test is the exception — it needs a **real** CGEvent, because it asserts on `kCGEventSourceUserData`, which a fake pointer cannot carry.

Add:

```zig
test "sequence completes on a forward of its own trigger" {
    const alloc = std.testing.allocator;
    var skhd = try createTestSkhdFromConfig(alloc, io, 
        \\cmd - q, cmd - q [ "Protected App" | cmd - q ]
    );
    defer skhd.deinit();

    const cmd_q = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = 0x0C };

    try std.testing.expectEqual(HotkeyResult.consumed, try skhd.processHotkey(&cmd_q, mock_event, "Protected App"));
    try std.testing.expectEqual(@as(usize, 1), skhd.sequence_prefix_len);

    // Second press completes and forwards. forwardKey no-ops under test.
    try std.testing.expectEqual(HotkeyResult.consumed, try skhd.processHotkey(&cmd_q, mock_event, "Protected App"));
    try std.testing.expectEqual(@as(usize, 0), skhd.sequence_prefix_len);

    // Elsewhere the sequence does not apply, so cmd-q passes through to macOS.
    try std.testing.expectEqual(HotkeyResult.not_found, try skhd.processHotkey(&cmd_q, mock_event, "Firefox"));
}

test "passthrough applies to the final chord only" {
    const alloc = std.testing.allocator;
    var skhd = try createTestSkhdFromConfig(alloc, io, "cmd - k, cmd - c -> : echo hi");
    defer skhd.deinit();

    const cmd_k = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = 0x28 };
    const cmd_c = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = 0x08 };

    // Chord 1 is consumed — completion isn't known yet, so delivering it
    // would send a cmd-k the user never meant to send.
    try std.testing.expectEqual(HotkeyResult.consumed, try skhd.processHotkey(&cmd_k, mock_event, "Any"));
    // Chord 2 completes: action fires and the key still goes through.
    try std.testing.expectEqual(HotkeyResult.passthrough, try skhd.processHotkey(&cmd_c, mock_event, "Any"));
}

test "mismatch mid-sequence reprocesses the chord from the root" {
    const alloc = std.testing.allocator;
    var skhd = try createTestSkhdFromConfig(alloc, io, 
        \\cmd - k, cmd - c : echo seq
        \\cmd - x : echo unrelated
    );
    defer skhd.deinit();

    const cmd_k = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = 0x28 };
    const cmd_x = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = 0x07 };

    try std.testing.expectEqual(HotkeyResult.consumed, try skhd.processHotkey(&cmd_k, mock_event, "Any"));
    // cmd-x doesn't continue the sequence, but must still fire its own rule
    // rather than being swallowed.
    try std.testing.expectEqual(HotkeyResult.consumed, try skhd.processHotkey(&cmd_x, mock_event, "Any"));
    try std.testing.expectEqual(@as(usize, 0), skhd.sequence_prefix_len);
}

test "process change cancels a pending sequence" {
    const alloc = std.testing.allocator;
    var skhd = try createTestSkhdFromConfig(alloc, io, 
        \\cmd - k, cmd - c [ "App A" : echo a ]
    );
    defer skhd.deinit();

    const cmd_k = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = 0x28 };
    const cmd_c = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = 0x08 };

    try std.testing.expectEqual(HotkeyResult.consumed, try skhd.processHotkey(&cmd_k, mock_event, "App A"));
    // A sequence must not begin in one app and execute against another.
    try std.testing.expectEqual(HotkeyResult.not_found, try skhd.processHotkey(&cmd_c, mock_event, "App B"));
    try std.testing.expectEqual(@as(usize, 0), skhd.sequence_prefix_len);
}

test "self-generated events never touch pending sequence state" {
    const alloc = std.testing.allocator;
    var skhd = try createTestSkhdFromConfig(alloc, io, 
        \\cmd - q, cmd - q : echo quit
    );
    defer skhd.deinit();

    const cmd_q = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = 0x0C };
    try std.testing.expectEqual(HotkeyResult.consumed, try skhd.processHotkey(&cmd_q, mock_event, "Any"));
    try std.testing.expectEqual(@as(usize, 1), skhd.sequence_prefix_len);

    // A marked event must return before any sequence handling. If the
    // marker check ever moves below it, a forwarded cmd-q re-enters,
    // matches this sequence's own first chord, goes pending, and the app
    // never receives the keypress.
    const marked = c.CGEventCreateKeyboardEvent(null, 0x0C, true);
    defer c.CFRelease(marked);
    c.CGEventSetFlags(marked, c.kCGEventFlagMaskCommand);
    c.CGEventSetIntegerValueField(marked, c.kCGEventSourceUserData, SKHD_EVENT_MARKER);

    const returned = try skhd.handleKeyDown(marked);
    // Passed through untouched, and the prefix is exactly as it was.
    try std.testing.expectEqual(marked, returned);
    try std.testing.expectEqual(@as(usize, 1), skhd.sequence_prefix_len);
}
```

Note `handleKeyDown` reads the frontmost app via `self.carbon_event.getProcessName()`, which returns `"unknown"` under test (`CarbonEvent.zig:35`) — that is fine here, because the marker check returns before the process name is consulted. This test is specifically about *reaching* that early return.

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: FAIL. `"passthrough applies to the final chord only"` is the one exercising real logic — if it fails, `processMatchedHotkey` is being reached on a pending chord rather than only on the completing one.

- [ ] **Step 3: Make the invariants explicit in the code**

`handleKeyDown`'s marker check (`src/skhd.zig:874-879`) is already above the sequence handling. Replace its comment so a later cleanup cannot reorder it:
```zig
    // Skip events we generated ourselves. This MUST stay above all
    // sequence handling: `cmd - q, cmd - q ["Terminal" | cmd - q]` forwards
    // a cmd-q that re-enters this tap (head-inserted at kCGSessionEventTap;
    // forwardKey posts to the same tap). If this check ran below, the
    // forward would match the sequence's own first chord, go pending, and be
    // swallowed — the app would never receive the quit. Returning here also
    // means a self-generated event never advances or cancels a pending
    // prefix, which is correct: our own synthesis is not user input.
    const marker = c.CGEventGetIntegerValueField(event, c.kCGEventSourceUserData);
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/skhd.zig
git commit -m "test: pin re-entrancy and final-chord passthrough invariants

The marker check must stay above sequence handling or a forward of the
sequence's own trigger gets swallowed by its own first chord. Passthrough
applies only to the completing chord, since earlier chords cannot be
delivered before completion is known."
```

---

### Task 6: Documentation and full verification

**Files:**
- Modify: `SYNTAX.md`, `README.md`

- [ ] **Step 1: Document the grammar in SYNTAX.md**

The branch already added a sequences section — reconcile it with the shipped design. It must state: comma-separated chords, each carrying its own modifiers; the 300ms interval; that `->` and `~` apply to the final chord; and the uniqueness rule with the worked examples from the spec's "Consequences, in each direction" block. Remove any wording implying sequences are a construct distinct from hotkeys — they are hotkeys with more than one chord, and every action form works on them.

- [ ] **Step 2: Update the README example**

Use the forwarding form, which needs no shell command:
```skhd
# Require two Cmd-Q presses to quit a protected app. Everywhere else the
# first Cmd-Q has no skhd binding, so it passes through and macOS quits
# normally. The second press forwards a real Cmd-Q.
cmd - q, cmd - q [ "Protected App" | cmd - q ]
```

- [ ] **Step 3: Verify nothing dangles**

```bash
grep -rn "Sequence" src/ build.zig ; echo "--- expect: no matches ---"
grep -rn "sequence_matcher\|add_sequence\|addSequence\|hotkey_owned\|TEMPORARY" src/ ; echo "--- expect: no matches ---"
grep -rn "flags\.passthrough\|hotkey\.flags\b\|hotkey\.key\b" src/ ; echo "--- expect: no matches ---"
```

- [ ] **Step 4: Full build and suite**

Run: `zig build test && zig build` (bench is pre-existing broken — see Global Constraints)
Expected: all pass.

- [ ] **Step 5: Parse the real config**

The user's config exercises capture modes, process groups, forwards, and layer wildcards — the paths most at risk from the lookup rewrite.

Run: `./zig-out/bin/skhd -c ~/.config/skhd/skhdrc -V 2>&1 | head -30`
Expected: parses with no error. `builtin.skhdrc` is pulled in via `.load`, so this covers both files.

- [ ] **Step 6: Verify the feature end-to-end**

REQUIRED SUB-SKILL: use the `verify` skill. Tests do not prove the event tap consumes and forwards correctly against a real application — drive the real binding.

Minimum: with `cmd - q, cmd - q [ "<some app>" | cmd - q ]` configured, confirm (a) one press does nothing and the app stays open, (b) two presses in quick succession quit it, (c) two presses slower than 300ms do nothing, and (d) `cmd-q` in a different app quits immediately.

- [ ] **Step 7: Commit**

```bash
git add SYNTAX.md README.md
git commit -m "docs: document hotkey sequences"
```

---

## Self-Review Notes

Spec sections mapped to tasks: Data Model → T2; passthrough hoist → T1; uniqueness rule → T3 (predicate) + T4 (enforcement); grammar coverage → T4 (parser, multi-mode test) + T5 (passthrough); prefix lookup + claim gate → T3 (context) + T4 (flow); runtime state / allocation-free → T4; cancellation → T4 (existing triggers retained; reload re-allocates the prefix buffer) + T5 (process change); re-entrancy → T5; testing → spread across T2–T5; documentation → T6.

Deliberately **not** in this plan: modifier-transparent forwarding. It is a separate feature with an open precedence model — see the spec's "Interaction With Modifier Transparency". Do not let it leak in.
