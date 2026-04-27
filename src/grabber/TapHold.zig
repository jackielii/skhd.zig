//! Tap-hold state machine for one rule.
//!
//! HID events come in one transition at a time (key X went up/down).
//! The FSM watches a single "source" usage: while it's held, the
//! engine swallows the source's normal output and waits to commit
//! either the **tap** action (a different key emitted as a brief
//! tap) or the **hold** action (a different key — typically a
//! modifier — emitted continuously while the source is held).
//!
//! QMK semantics, with the same knobs Karabiner exposes:
//!
//! - `timeout_ms`: source held > this → commit hold. Default 200ms.
//! - `hold_on_other_key_press`: any other key down before the timer
//!   fires immediately commits the hold (and lets the other key
//!   pass through under the held mod). Default off.
//! - `permissive_hold`: another key fully tapped (down + up) while
//!   the source is held commits the hold (the buffered other key
//!   is then re-emitted under the held mod). Default off.
//! - `retro_tap`: deferred to a follow-up phase.
//!
//! The owner runs the timer (CFRunLoopTimer in production); this
//! file only manages the FSM. Each `feed()` / `timerFired()` returns
//! a `TimerAction` describing what the owner should do with the
//! pending timer (start/cancel/leave-alone) and emits any
//! synthesized HID events through the sink callback.

const std = @import("std");

const log = std.log.scoped(.taphold);

/// One HID transition. Mirrors the shape used by the seize callback
/// so the same struct flows through TapHold and KbState.
pub const Event = struct {
    usage_page: u32,
    usage: u32,
    pressed: bool,
};

pub const Rule = struct {
    src_usage: u16,
    tap_usage: u16,
    hold_usage: u16,
    timeout_ms: u32 = 200,
    permissive_hold: bool = false,
    hold_on_other_key_press: bool = false,
    retro_tap: bool = false,
};

/// What the owner should do with its timer after the engine
/// returned. Only one of `start_in_ms` / `cancel` is meaningful per
/// call.
pub const TimerAction = union(enum) {
    none,
    start_in_ms: u32,
    cancel,
};

/// Sink for synthesized HID events. Called synchronously from
/// `feed`/`timerFired` for every emitted transition. The owner's
/// implementation is expected to update its KbState and post the
/// resulting report to vhidd.
pub const Sink = *const fn (ctx: ?*anyopaque, ev: Event) void;

/// Disposition of an incoming event: pass = the engine doesn't care
/// about this usage, owner should forward; consumed = engine handled
/// it (possibly by emitting through the sink).
pub const Disposition = enum { pass, consumed };

const State = enum {
    idle,
    /// Source is held, timer running, no decision yet. Other keys
    /// may be pending in `buffer` if permissive_hold is on.
    pending,
    /// Hold action committed and emitted. Source still held.
    decided_hold,
};

/// Buffer used in permissive_hold mode to hold "other key" events
/// that arrived between source_down and source_up. We only need a
/// few slots — most users don't pile up keys faster than the
/// timeout.
const max_buffered_events = 16;

rule: Rule,
state: State = .idle,
sink: Sink,
sink_ctx: ?*anyopaque,
buffer: std.BoundedArray(Event, max_buffered_events) = .{},

const Self = @This();

pub fn init(rule: Rule, sink: Sink, sink_ctx: ?*anyopaque) Self {
    return .{ .rule = rule, .sink = sink, .sink_ctx = sink_ctx };
}

pub fn feed(self: *Self, ev: Event) struct { disposition: Disposition, timer: TimerAction } {
    const is_source = ev.usage_page == 0x07 and ev.usage == self.rule.src_usage;

    switch (self.state) {
        .idle => {
            if (is_source and ev.pressed) {
                self.state = .pending;
                return .{ .disposition = .consumed, .timer = .{ .start_in_ms = self.rule.timeout_ms } };
            }
            // Source key-up while idle (e.g. stuck-key recovery): nothing
            // for us to do; let the owner pass it through.
            return .{ .disposition = .pass, .timer = .none };
        },

        .pending => {
            if (is_source) {
                if (!ev.pressed) {
                    // Source released before timeout / before any
                    // permissive-hold trigger → it was a tap.
                    self.commitTap();
                    return .{ .disposition = .consumed, .timer = .cancel };
                }
                // Source-down repeated (key repeat at the OS level
                // rarely fires here since seize is per-event, but
                // be defensive). Stay in pending.
                return .{ .disposition = .consumed, .timer = .none };
            }

            // Other key arrived while pending.
            if (self.rule.hold_on_other_key_press and ev.pressed) {
                // Eager commit: the moment another key is pressed,
                // we know the user is using the source as a hold.
                self.emitHoldDown();
                self.state = .decided_hold;
                self.flushBuffer();
                return .{ .disposition = .pass, .timer = .cancel };
            }

            if (self.rule.permissive_hold) {
                // Buffer everything; the next other-key-up tells us
                // it was tapped during the source hold → commit hold.
                self.buffer.append(ev) catch {
                    log.warn("permissive_hold buffer overflow — flushing as tap", .{});
                    self.commitTap();
                    return .{ .disposition = .pass, .timer = .cancel };
                };
                if (!ev.pressed) {
                    // Other key was tapped (down + up) while source
                    // held → commit hold, replay buffered events
                    // under the held mod.
                    self.emitHoldDown();
                    self.state = .decided_hold;
                    self.flushBuffer();
                    return .{ .disposition = .consumed, .timer = .cancel };
                }
                return .{ .disposition = .consumed, .timer = .none };
            }

            // Default behaviour: other keys pass through immediately
            // and we keep waiting for source_up or timeout.
            return .{ .disposition = .pass, .timer = .none };
        },

        .decided_hold => {
            if (is_source) {
                if (!ev.pressed) {
                    // Hold finished.
                    self.emitHoldUp();
                    self.state = .idle;
                    return .{ .disposition = .consumed, .timer = .none };
                }
                // Source-down repeated while already held — same
                // story as in pending; stay put.
                return .{ .disposition = .consumed, .timer = .none };
            }
            // Anything else just flows through under the held mod.
            return .{ .disposition = .pass, .timer = .none };
        },
    }
}

pub fn timerFired(self: *Self) TimerAction {
    if (self.state != .pending) return .none;
    self.emitHoldDown();
    self.state = .decided_hold;
    self.flushBuffer();
    return .none;
}

fn commitTap(self: *Self) void {
    log.info("commit tap: src=0x{X:0>2} → tap=0x{X:0>2}", .{ self.rule.src_usage, self.rule.tap_usage });
    self.emit(self.rule.tap_usage, true);
    self.emit(self.rule.tap_usage, false);
    // After tap, replay any buffered events in their original order.
    self.flushBuffer();
    self.state = .idle;
}

fn emitHoldDown(self: *Self) void {
    log.info("commit hold: src=0x{X:0>2} → hold=0x{X:0>2} down", .{ self.rule.src_usage, self.rule.hold_usage });
    self.emit(self.rule.hold_usage, true);
}

fn emitHoldUp(self: *Self) void {
    log.info("commit hold: src=0x{X:0>2} → hold=0x{X:0>2} up", .{ self.rule.src_usage, self.rule.hold_usage });
    self.emit(self.rule.hold_usage, false);
}

fn emit(self: *Self, usage: u16, pressed: bool) void {
    self.sink(self.sink_ctx, .{
        .usage_page = 0x07,
        .usage = usage,
        .pressed = pressed,
    });
}

fn flushBuffer(self: *Self) void {
    for (self.buffer.constSlice()) |ev| {
        self.sink(self.sink_ctx, ev);
    }
    self.buffer.clear();
}

// ─── tests ───────────────────────────────────────────────────────

const TestSink = struct {
    out: std.ArrayList(Event),

    fn init(allocator: std.mem.Allocator) TestSink {
        return .{ .out = std.ArrayList(Event).init(allocator) };
    }

    fn deinit(self: *TestSink) void {
        self.out.deinit();
    }

    fn callback(ctx: ?*anyopaque, ev: Event) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        self.out.append(ev) catch unreachable;
    }
};

fn kbev(usage: u16, pressed: bool) Event {
    return .{ .usage_page = 0x07, .usage = usage, .pressed = pressed };
}

test "tap path: quick source up emits tap_down + tap_up" {
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var eng = init(.{ .src_usage = 0x39, .tap_usage = 0x29, .hold_usage = 0xE0 }, TestSink.callback, &sink);

    const r1 = eng.feed(kbev(0x39, true));
    try std.testing.expectEqual(Disposition.consumed, r1.disposition);
    try std.testing.expectEqual(TimerAction{ .start_in_ms = 200 }, r1.timer);
    try std.testing.expectEqual(@as(usize, 0), sink.out.items.len);

    const r2 = eng.feed(kbev(0x39, false));
    try std.testing.expectEqual(Disposition.consumed, r2.disposition);
    try std.testing.expectEqual(TimerAction.cancel, r2.timer);
    try std.testing.expectEqual(@as(usize, 2), sink.out.items.len);
    try std.testing.expectEqual(@as(u32, 0x29), sink.out.items[0].usage);
    try std.testing.expect(sink.out.items[0].pressed);
    try std.testing.expectEqual(@as(u32, 0x29), sink.out.items[1].usage);
    try std.testing.expect(!sink.out.items[1].pressed);
}

test "hold path: timer fires emits hold_down, source up emits hold_up" {
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var eng = init(.{ .src_usage = 0x39, .tap_usage = 0x29, .hold_usage = 0xE0 }, TestSink.callback, &sink);

    _ = eng.feed(kbev(0x39, true));
    _ = eng.timerFired();
    try std.testing.expectEqual(@as(usize, 1), sink.out.items.len);
    try std.testing.expectEqual(@as(u32, 0xE0), sink.out.items[0].usage);
    try std.testing.expect(sink.out.items[0].pressed);

    const r = eng.feed(kbev(0x39, false));
    try std.testing.expectEqual(Disposition.consumed, r.disposition);
    try std.testing.expectEqual(@as(usize, 2), sink.out.items.len);
    try std.testing.expectEqual(@as(u32, 0xE0), sink.out.items[1].usage);
    try std.testing.expect(!sink.out.items[1].pressed);
}

test "default: other key passes through during pending without committing" {
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var eng = init(.{ .src_usage = 0x39, .tap_usage = 0x29, .hold_usage = 0xE0 }, TestSink.callback, &sink);

    _ = eng.feed(kbev(0x39, true));
    const r = eng.feed(kbev(0x04, true)); // 'a' down
    try std.testing.expectEqual(Disposition.pass, r.disposition);
    try std.testing.expectEqual(TimerAction.none, r.timer);
    try std.testing.expectEqual(@as(usize, 0), sink.out.items.len);

    // Source release within timeout still commits a tap (default
    // behaviour — other-key-down does not flip the decision).
    _ = eng.feed(kbev(0x39, false));
    try std.testing.expectEqual(@as(usize, 2), sink.out.items.len);
    try std.testing.expectEqual(@as(u32, 0x29), sink.out.items[0].usage);
}

test "hold_on_other_key_press: other-key-down immediately commits hold" {
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var eng = init(.{
        .src_usage = 0x39,
        .tap_usage = 0x29,
        .hold_usage = 0xE0,
        .hold_on_other_key_press = true,
    }, TestSink.callback, &sink);

    _ = eng.feed(kbev(0x39, true));
    const r = eng.feed(kbev(0x04, true));
    try std.testing.expectEqual(Disposition.pass, r.disposition);
    try std.testing.expectEqual(TimerAction.cancel, r.timer);
    try std.testing.expectEqual(@as(usize, 1), sink.out.items.len);
    try std.testing.expectEqual(@as(u32, 0xE0), sink.out.items[0].usage);
    try std.testing.expect(sink.out.items[0].pressed);
}

test "permissive_hold: other-key tap during source-held commits hold + replays" {
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var eng = init(.{
        .src_usage = 0x39,
        .tap_usage = 0x29,
        .hold_usage = 0xE0,
        .permissive_hold = true,
    }, TestSink.callback, &sink);

    _ = eng.feed(kbev(0x39, true));
    const r1 = eng.feed(kbev(0x04, true)); // 'a' down — buffered
    try std.testing.expectEqual(Disposition.consumed, r1.disposition);
    try std.testing.expectEqual(@as(usize, 0), sink.out.items.len);

    const r2 = eng.feed(kbev(0x04, false)); // 'a' up — commits hold + replays
    try std.testing.expectEqual(Disposition.consumed, r2.disposition);
    try std.testing.expectEqual(TimerAction.cancel, r2.timer);
    // Output: hold_down (0xE0 down), then buffered a-down, then a-up.
    try std.testing.expectEqual(@as(usize, 3), sink.out.items.len);
    try std.testing.expectEqual(@as(u32, 0xE0), sink.out.items[0].usage);
    try std.testing.expect(sink.out.items[0].pressed);
    try std.testing.expectEqual(@as(u32, 0x04), sink.out.items[1].usage);
    try std.testing.expect(sink.out.items[1].pressed);
    try std.testing.expectEqual(@as(u32, 0x04), sink.out.items[2].usage);
    try std.testing.expect(!sink.out.items[2].pressed);
}

test "permissive_hold: source up before other-key up emits tap then replays" {
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var eng = init(.{
        .src_usage = 0x39,
        .tap_usage = 0x29,
        .hold_usage = 0xE0,
        .permissive_hold = true,
    }, TestSink.callback, &sink);

    _ = eng.feed(kbev(0x39, true));
    _ = eng.feed(kbev(0x04, true));
    const r = eng.feed(kbev(0x39, false));
    try std.testing.expectEqual(Disposition.consumed, r.disposition);
    // Output: tap_down, tap_up, then replayed a-down.
    try std.testing.expectEqual(@as(usize, 3), sink.out.items.len);
    try std.testing.expectEqual(@as(u32, 0x29), sink.out.items[0].usage);
    try std.testing.expectEqual(@as(u32, 0x29), sink.out.items[1].usage);
    try std.testing.expectEqual(@as(u32, 0x04), sink.out.items[2].usage);
}

test "decided_hold: source up after timer emits hold_up exactly once" {
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var eng = init(.{ .src_usage = 0x39, .tap_usage = 0x29, .hold_usage = 0xE0 }, TestSink.callback, &sink);

    _ = eng.feed(kbev(0x39, true));
    _ = eng.timerFired();
    _ = eng.feed(kbev(0x04, true)); // 'a' down — passes through
    _ = eng.feed(kbev(0x04, false));
    _ = eng.feed(kbev(0x39, false));

    // Output: hold_down (timer), hold_up (source-up). The 'a' events
    // are pass-through and not in our sink.
    try std.testing.expectEqual(@as(usize, 2), sink.out.items.len);
    try std.testing.expect(sink.out.items[0].pressed);
    try std.testing.expect(!sink.out.items[1].pressed);
}

test "non-source events while idle: pass through, FSM untouched" {
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var eng = init(.{ .src_usage = 0x39, .tap_usage = 0x29, .hold_usage = 0xE0 }, TestSink.callback, &sink);

    const r = eng.feed(kbev(0x04, true));
    try std.testing.expectEqual(Disposition.pass, r.disposition);
    try std.testing.expectEqual(TimerAction.none, r.timer);
    try std.testing.expectEqual(@as(usize, 0), sink.out.items.len);
    try std.testing.expectEqual(State.idle, eng.state);
}
