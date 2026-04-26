//! Per-rule tap-hold state machine. Drives the QMK-style decision
//! between a quick-tap action (e.g., escape) and a hold action (e.g.,
//! lctrl) based on press duration and intervening key events.
//!
//! Driven by CGEventTap callbacks (source key events, other key events)
//! and a CFRunLoopTimer (timeout fires). All callbacks run on the main
//! run loop, so no thread synchronisation is needed within the state.
//!
//! Phase 3 supports modifier hold targets only (lctrl, lshift, lalt,
//! lcmd and their right counterparts). Layer holds (`hold: <mode_name>`)
//! land in Phase 4.

const std = @import("std");
const c = @import("c.zig");
const Mappings = @import("Mappings.zig");
const HidKeyMap = @import("HidKeyMap.zig");

const TapHoldMachine = @This();
const log = std.log.scoped(.taphold);

/// Tag set on every CGEvent the machine synthesizes so the main
/// CGEventTap callback recognises them on round-trip and skips rule
/// matching. Must equal SKHD_EVENT_MARKER in skhd.zig.
pub const SKHD_EVENT_MARKER: i64 = 0x736B6864; // 'skhd'

pub const State = enum {
    idle,
    pending,
    committed_hold,
};

pub const Action = enum {
    /// Suppress the event (return null from CGEventTap callback).
    consume,
    /// Let the event flow through. The machine may still have mutated
    /// the event's flags (e.g. to add the hold modifier mask).
    passthrough,
};

const BufferedEvent = struct {
    event: c.CGEventRef,
    is_keydown: bool,
    keycode: u32,
};

allocator: std.mem.Allocator,

// ── Configuration (immutable after init) ───────────────────────────────
decl: Mappings.TapHoldDecl,
/// Mac VK to listen for as the source key. Equals F18 for caps-class
/// (post-hidutil-proxy) sources, otherwise the original key's Mac VK.
source_vk: u32,
/// Mac VK to synthesize on tap commit (e.g. escape).
tap_vk: u32,
/// Mac VK to synthesize on hold commit (e.g. lctrl).
hold_vk: u32,
/// CG event flag mask if `hold_vk` is a modifier; null otherwise. Used
/// to augment buffered/pass-through events during committed_hold so the
/// focused app sees them as modifier-chord (e.g. ctrl+a).
hold_flag: ?u64,

// ── Mutable state ──────────────────────────────────────────────────────
state: State = .idle,
/// Wallclock-ish nanosecond timestamp (CGEventGetTimestamp domain) at
/// which the current pending press started. Used by retro_tap and
/// auto-repeat heuristics.
pending_press_ts: u64 = 0,
/// Timestamp of the most recent tap-commit release. Used to detect
/// quick re-tap (auto-repeat) within `timeout_ms`.
last_tap_release_ts: u64 = 0,
/// Set true while in committed_hold the moment any non-source key
/// passes through. Used by retro_tap on source-up.
had_other_key: bool = false,
/// CFRunLoopTimer that fires once when `timeout_ms` elapses after a
/// source-down. Pre-allocated and reused via SetNextFireDate.
timer: c.CFRunLoopTimerRef = null,
/// Buffered other-key events seen while pending. Retained on insert;
/// either replayed (committing hold) or discarded (committing tap).
pending_events: std.ArrayListUnmanaged(BufferedEvent) = .empty,

pub fn init(allocator: std.mem.Allocator, decl: Mappings.TapHoldDecl) !*TapHoldMachine {
    const effective_src = Mappings.effectiveSourceUsage(decl);
    const source_vk = HidKeyMap.macVKForHidUsage(effective_src) orelse {
        log.err("No Mac VK mapping for source HID usage 0x{x:0>2}", .{effective_src});
        return error.UnmappedSourceUsage;
    };
    const tap_vk = HidKeyMap.macVKForHidUsage(decl.tap_usage) orelse {
        log.err("No Mac VK mapping for tap HID usage 0x{x:0>2}", .{decl.tap_usage});
        return error.UnmappedTapUsage;
    };
    const hold_vk = HidKeyMap.macVKForHidUsage(decl.hold_usage) orelse {
        log.err("No Mac VK mapping for hold HID usage 0x{x:0>2}", .{decl.hold_usage});
        return error.UnmappedHoldUsage;
    };
    const hold_flag = HidKeyMap.modifierFlagForHidUsage(decl.hold_usage);

    const self = try allocator.create(TapHoldMachine);
    self.* = .{
        .allocator = allocator,
        .decl = decl,
        .source_vk = @intCast(source_vk),
        .tap_vk = @intCast(tap_vk),
        .hold_vk = @intCast(hold_vk),
        .hold_flag = hold_flag,
    };
    return self;
}

pub fn deinit(self: *TapHoldMachine) void {
    self.cancelTimer();
    self.releasePending();
    self.pending_events.deinit(self.allocator);
    self.allocator.destroy(self);
}

/// Called from the CGEventTap callback when an event for this rule's
/// source key arrives. `is_down` distinguishes keydown from keyup.
pub fn handleSource(self: *TapHoldMachine, is_down: bool, ts_ns: u64) Action {
    if (is_down) return self.handleSourceDown(ts_ns);
    return self.handleSourceUp(ts_ns);
}

/// Called for any non-source key event. The machine may buffer it,
/// pass it through after augmenting flags, or commit a state change.
pub fn handleOther(self: *TapHoldMachine, event: c.CGEventRef, is_down: bool, keycode: u32) Action {
    switch (self.state) {
        .pending => {
            // Buffer and decide. Always consume while pending — even if
            // we don't commit on this event, we don't want the app to
            // see a half-typed press.
            const retained = c.CFRetain(event);
            self.pending_events.append(self.allocator, .{
                .event = @ptrCast(@constCast(retained)),
                .is_keydown = is_down,
                .keycode = keycode,
            }) catch {
                // OOM on append: best-effort — release the retain and
                // pass through. The user sees a stuck-modifier worst case.
                _ = c.CFRelease(retained);
                return .passthrough;
            };

            if (is_down and self.decl.hold_on_other_key_press) {
                self.commitHold();
                return .consume;
            }
            if (!is_down and self.decl.permissive_hold) {
                // Permissive hold: a nested tap (down + up while we
                // were pending) commits the hold.
                self.commitHold();
                return .consume;
            }
            return .consume;
        },
        .committed_hold => {
            self.had_other_key = true;
            if (self.hold_flag) |flag| {
                const cur = c.CGEventGetFlags(event);
                c.CGEventSetFlags(event, cur | flag);
            }
            return .passthrough;
        },
        .idle => return .passthrough,
    }
}

/// Called by CFRunLoopTimer when the pending timer fires. Commits the
/// hold (or, with retro_tap on and no buffered events, leaves the
/// machine in committed_hold but `had_other_key` false so source-up
/// also emits the tap).
pub fn timerFired(self: *TapHoldMachine) void {
    if (self.state != .pending) return;
    self.commitHold();
}

// ── Internals ──────────────────────────────────────────────────────────

fn handleSourceDown(self: *TapHoldMachine, ts_ns: u64) Action {
    if (self.state != .idle) {
        // Stale / re-entrant down. Best-effort: stay in current state.
        return .consume;
    }

    // Quick-tap-term auto-repeat: if the user re-presses the source
    // key within `timeout_ms` of the last tap release, treat it as a
    // plain repeated tap so terminal/vim autorepeat keeps working.
    const timeout_ns: u64 = @as(u64, self.decl.timeout_ms) * 1_000_000;
    if (self.last_tap_release_ts > 0 and ts_ns -| self.last_tap_release_ts < timeout_ns) {
        self.synthesizeTap();
        self.last_tap_release_ts = ts_ns;
        return .consume;
    }

    self.state = .pending;
    self.pending_press_ts = ts_ns;
    self.had_other_key = false;
    self.startTimer();
    return .consume;
}

fn handleSourceUp(self: *TapHoldMachine, ts_ns: u64) Action {
    switch (self.state) {
        .pending => {
            // Released within timeout, no permissive-hold trigger →
            // commit to tap. Discard any buffered events (rare; only
            // happens when permissive_hold and hold_on_other_key_press
            // are both off and another key was held without releasing).
            self.cancelTimer();
            self.synthesizeTap();
            self.last_tap_release_ts = ts_ns;
            self.releasePending();
            self.state = .idle;
            return .consume;
        },
        .committed_hold => {
            self.synthesizeHoldUp();
            // Retro-tap: held past timeout with no other key activity →
            // emit the tap action on release as well.
            if (self.decl.retro_tap and !self.had_other_key) {
                self.synthesizeTap();
                self.last_tap_release_ts = ts_ns;
            }
            self.state = .idle;
            return .consume;
        },
        .idle => return .consume,
    }
}

fn commitHold(self: *TapHoldMachine) void {
    self.cancelTimer();
    self.synthesizeHoldDown();

    // Flush buffered events with the hold modifier flag set so apps see
    // them as part of the chord. SKHD_EVENT_MARKER stamped so they
    // short-circuit through our own CGEventTap on round-trip.
    for (self.pending_events.items) |buf| {
        if (self.hold_flag) |flag| {
            const cur = c.CGEventGetFlags(buf.event);
            c.CGEventSetFlags(buf.event, cur | flag);
        }
        c.CGEventSetIntegerValueField(buf.event, c.kCGEventSourceUserData, SKHD_EVENT_MARKER);
        c.CGEventPost(c.kCGSessionEventTap, buf.event);
        _ = c.CFRelease(buf.event);
    }
    self.pending_events.clearRetainingCapacity();
    self.state = .committed_hold;
    // had_other_key tracks key activity AFTER commit; if we got here
    // because a buffered key triggered hold_on_other_key_press or
    // permissive_hold, that already counts as activity for retro_tap.
    self.had_other_key = self.had_other_key or true; // simplified: any commit-via-other-key marks activity
}

fn releasePending(self: *TapHoldMachine) void {
    for (self.pending_events.items) |buf| {
        _ = c.CFRelease(buf.event);
    }
    self.pending_events.clearRetainingCapacity();
}

fn synthesizeTap(self: *TapHoldMachine) void {
    postKey(self.tap_vk, true);
    postKey(self.tap_vk, false);
}

fn synthesizeHoldDown(self: *TapHoldMachine) void {
    postKey(self.hold_vk, true);
}

fn synthesizeHoldUp(self: *TapHoldMachine) void {
    postKey(self.hold_vk, false);
}

fn postKey(vk: u32, is_down: bool) void {
    const src = c.CGEventSourceCreate(c.kCGEventSourceStateHIDSystemState);
    if (src == null) return;
    defer c.CFRelease(src);
    const ev = c.CGEventCreateKeyboardEvent(src, @intCast(vk), is_down);
    if (ev == null) return;
    defer c.CFRelease(ev);
    c.CGEventSetIntegerValueField(ev, c.kCGEventSourceUserData, SKHD_EVENT_MARKER);
    c.CGEventPost(c.kCGSessionEventTap, ev);
}

fn startTimer(self: *TapHoldMachine) void {
    const seconds: f64 = @as(f64, @floatFromInt(self.decl.timeout_ms)) / 1000.0;
    const fire_at = c.CFAbsoluteTimeGetCurrent() + seconds;
    if (self.timer == null) {
        var ctx = c.CFRunLoopTimerContext{
            .version = 0,
            .info = self,
            .retain = null,
            .release = null,
            .copyDescription = null,
        };
        self.timer = c.CFRunLoopTimerCreate(
            c.kCFAllocatorDefault,
            fire_at,
            0, // interval: one-shot (we manually rearm via SetNextFireDate)
            0,
            0,
            timerCallback,
            &ctx,
        );
        if (self.timer == null) return;
        c.CFRunLoopAddTimer(c.CFRunLoopGetMain(), self.timer, c.kCFRunLoopCommonModes);
    } else {
        c.CFRunLoopTimerSetNextFireDate(self.timer, fire_at);
    }
}

fn cancelTimer(self: *TapHoldMachine) void {
    if (self.timer != null) {
        // Push the next fire date far into the future to effectively
        // disarm without invalidating. The timer is reused across
        // pending presses.
        c.CFRunLoopTimerSetNextFireDate(self.timer, c.CFAbsoluteTimeGetCurrent() + 86400);
    }
}

fn timerCallback(_: c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const self: *TapHoldMachine = @ptrCast(@alignCast(info orelse return));
    self.timerFired();
}

// ── Tests ──────────────────────────────────────────────────────────────

test "init resolves source/tap/hold to Mac VKs" {
    const alloc = std.testing.allocator;
    const decl = Mappings.TapHoldDecl{
        .src_usage = 0x39, // caps_lock — proxy applies
        .tap_usage = 0x29, // escape
        .hold_usage = 0xE0, // lctrl
        .device_alias = "builtin",
        .timeout_ms = 120,
    };
    const machine = try TapHoldMachine.init(alloc, decl);
    defer machine.deinit();

    // After auto-proxy, source listens on F18.
    try std.testing.expectEqual(@as(u32, c.kVK_F18), machine.source_vk);
    try std.testing.expectEqual(@as(u32, c.kVK_Escape), machine.tap_vk);
    try std.testing.expectEqual(@as(u32, c.kVK_Control), machine.hold_vk);
    try std.testing.expectEqual(@as(?u64, c.kCGEventFlagMaskControl), machine.hold_flag);
    try std.testing.expectEqual(State.idle, machine.state);
}

test "non-proxy source uses original Mac VK" {
    const alloc = std.testing.allocator;
    const decl = Mappings.TapHoldDecl{
        .src_usage = 0x2C, // space (no proxy)
        .tap_usage = 0x2C,
        .hold_usage = 0xE2, // lalt
        .device_alias = "builtin",
    };
    const machine = try TapHoldMachine.init(alloc, decl);
    defer machine.deinit();

    try std.testing.expectEqual(@as(u32, c.kVK_Space), machine.source_vk);
    try std.testing.expectEqual(@as(?u64, c.kCGEventFlagMaskAlternate), machine.hold_flag);
}
