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

/// What to do when a tap-hold rule commits its hold action.
pub const HoldAction = union(enum) {
    /// Emit a HID page-7 usage (modifier or any key). Used for
    /// caps_lock → ctrl, etc.
    hid_usage: u16,
    /// Push a named mode onto the agent. Used for layer holds like
    /// `space → fn_layer`. Lifetime: the engine borrows the slice;
    /// caller keeps it valid until the engine is dropped.
    layer: []const u8,
};

pub const Rule = struct {
    src_usage: u16,
    tap_usage: u16,
    hold: HoldAction,
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

/// Sink for layer enter/exit events. Called when a layer-hold rule
/// commits or releases. `entering = true` means push the named layer;
/// `entering = false` means pop back to the previous mode (the owner
/// implements that semantic — the engine doesn't track stack depth).
pub const LayerSink = *const fn (ctx: ?*anyopaque, layer: []const u8, entering: bool) void;

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
/// Optional layer sink — required if rule.hold is a layer; ignored
/// otherwise. Owner's responsibility.
layer_sink: ?LayerSink = null,
layer_sink_ctx: ?*anyopaque = null,
/// Optional arbitration hook. Invoked just before this rule's
/// hold commit lands at the sink (permissive_hold or
/// hold_on_other_key_press triggers, and timer fire). Gives the
/// owning dispatcher a chance to coordinate with other still-
/// pending slots — e.g. force a pending layer slot to push its
/// layer first, so the agent sees the layer transition before
/// this slot's modifier-down arrives at the OS. The hook is not
/// called on the tap path.
arbitration_hook: ?*const fn (ctx: ?*anyopaque, committing: *@This()) void = null,
arbitration_ctx: ?*anyopaque = null,
// std.BoundedArray was removed in 0.16. We hold the storage inline
// and track the live length separately so the data is address-stable
// across struct moves (an ArrayList view's `.items.ptr` would point at
// the now-stale function frame after `init` returns by value).
buffer_storage: [max_buffered_events]Event = undefined,
buffer_len: usize = 0,
/// HID usages currently parked in `buffer` as a still-pressed down
/// (not yet matched by an up). Used to decide whether an arriving
/// key-up should be buffered (its down was buffered, replay them
/// together to preserve order) or passed through immediately (its
/// down was emitted before the pending window — buffering the up
/// would let the OS see the key as held for the entire pending
/// window and autorepeat it).
buffered_downs_storage: [max_buffered_events]u16 = undefined,
buffered_downs_len: usize = 0,
/// Whether any non-source key event has been seen since this rule
/// last entered pending. Drives `retro_tap` (emit tap on release if
/// nothing else was pressed during the hold).
other_key_seen: bool = false,

const Self = @This();

inline fn bufferItems(self: *Self) []Event {
    return self.buffer_storage[0..self.buffer_len];
}

inline fn bufferedDownsItems(self: *Self) []u16 {
    return self.buffered_downs_storage[0..self.buffered_downs_len];
}

inline fn pushBuffer(self: *Self, ev: Event) error{OutOfMemory}!void {
    if (self.buffer_len >= self.buffer_storage.len) return error.OutOfMemory;
    self.buffer_storage[self.buffer_len] = ev;
    self.buffer_len += 1;
}

inline fn pushBufferedDown(self: *Self, usage: u16) error{OutOfMemory}!void {
    if (self.buffered_downs_len >= self.buffered_downs_storage.len) return error.OutOfMemory;
    self.buffered_downs_storage[self.buffered_downs_len] = usage;
    self.buffered_downs_len += 1;
}

pub fn init(rule: Rule, sink: Sink, sink_ctx: ?*anyopaque) Self {
    return .{ .rule = rule, .sink = sink, .sink_ctx = sink_ctx };
}

pub fn initWithLayerSink(
    rule: Rule,
    sink: Sink,
    sink_ctx: ?*anyopaque,
    layer_sink: LayerSink,
    layer_sink_ctx: ?*anyopaque,
) Self {
    return .{
        .rule = rule,
        .sink = sink,
        .sink_ctx = sink_ctx,
        .layer_sink = layer_sink,
        .layer_sink_ctx = layer_sink_ctx,
    };
}

pub fn feed(self: *Self, ev: Event) struct { disposition: Disposition, timer: TimerAction } {
    const is_source = ev.usage_page == 0x07 and ev.usage == self.rule.src_usage;

    switch (self.state) {
        .idle => {
            if (is_source and ev.pressed) {
                self.state = .pending;
                self.other_key_seen = false;
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

            // Track for retro_tap.
            self.other_key_seen = true;

            // Other key arrived while pending.
            if (self.rule.hold_on_other_key_press and ev.pressed) {
                // Eager commit: the moment another key is pressed,
                // we know the user is using the source as a hold.
                self.doHoldCommit();
                return .{ .disposition = .pass, .timer = .cancel };
            }

            // Layer rules always buffer non-source events through the
            // pending window so the typing order is preserved when we
            // commit. permissive_hold buffers too, but additionally
            // treats a nested tap as proof of intent-to-hold (used by
            // modifier-style rules; doesn't fit layer holds well).
            if (self.isLayer() or self.rule.permissive_hold) {
                const ev_usage16: u16 = std.math.cast(u16, ev.usage) orelse 0;
                if (!ev.pressed) {
                    // For an UP event, only buffer if the matching
                    // DOWN was also buffered. Otherwise the down is
                    // already at the OS and delaying the up would
                    // let the OS see the key as held for the entire
                    // pending window — at which point autorepeat
                    // fires and a single physical press shows up as
                    // many characters.
                    var down_was_buffered = false;
                    var i: usize = 0;
                    while (i < self.buffered_downs_len) : (i += 1) {
                        if (self.buffered_downs_storage[i] == ev_usage16) {
                            // swap-remove
                            self.buffered_downs_len -= 1;
                            self.buffered_downs_storage[i] = self.buffered_downs_storage[self.buffered_downs_len];
                            down_was_buffered = true;
                            break;
                        }
                    }
                    if (!down_was_buffered) {
                        log.debug("pass-through up: src=0x{X:0>2} usage=0x{X:0>2} (down was external)", .{ self.rule.src_usage, ev.usage });
                        return .{ .disposition = .pass, .timer = .none };
                    }
                }
                self.pushBuffer(ev) catch {
                    log.warn("buffer overflow — flushing as tap", .{});
                    self.commitTap();
                    return .{ .disposition = .pass, .timer = .cancel };
                };
                if (ev.pressed) {
                    self.pushBufferedDown(ev_usage16) catch {};
                }
                log.debug("buffer: slot src=0x{X:0>2} +usage=0x{X:0>2} pressed={} (depth={d})", .{ self.rule.src_usage, ev.usage, ev.pressed, self.buffer_len });
                if (self.rule.permissive_hold and !self.isLayer() and !ev.pressed) {
                    // Modifier-style permissive_hold: nested down+up
                    // commits hold and replays the inner key under
                    // the modifier. Layer holds skip this — it
                    // misclassifies natural typing roll-overs (where
                    // user presses next letter before releasing the
                    // layer key) as deliberate layer use.
                    self.doHoldCommit();
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
                    // QMK retro_tap: if no other key was pressed
                    // during the entire hold window, fall back to
                    // emitting the tap action on release. Lets a
                    // user who accidentally over-held the source key
                    // still get the character (or whatever the tap
                    // action is) without losing it.
                    if (self.rule.retro_tap and !self.other_key_seen) {
                        log.info("retro_tap: no other key seen — emit tap on release", .{});
                        self.emit(self.rule.tap_usage, true);
                        self.emit(self.rule.tap_usage, false);
                    }
                    self.state = .idle;
                    return .{ .disposition = .consumed, .timer = .none };
                }
                // Source-down repeated while already held — same
                // story as in pending; stay put.
                return .{ .disposition = .consumed, .timer = .none };
            }
            // Anything else just flows through under the held mod.
            self.other_key_seen = true;
            return .{ .disposition = .pass, .timer = .none };
        },
    }
}

pub fn timerFired(self: *Self) TimerAction {
    if (self.state != .pending) return .none;
    self.doHoldCommit();
    return .none;
}

pub fn isLayer(self: *const Self) bool {
    return std.meta.activeTag(self.rule.hold) == .layer;
}

/// Internal: emit the hold action and flush the buffer, with
/// arbitration hook called first so dispatchers can reorder
/// other slots' state before this slot's emit lands at the sink.
fn doHoldCommit(self: *Self) void {
    if (self.arbitration_hook) |h| h(self.arbitration_ctx, self);
    self.emitHoldDown();
    self.state = .decided_hold;
    self.flushBuffer();
}

/// Number of events currently buffered (used by arbitration
/// to compute the "unique prefix" shared with a peer slot).
pub fn bufferedCount(self: *const Self) usize {
    return self.buffer_len;
}

/// Force a pending layer rule to push its layer immediately and
/// transition to decided_hold. The buffer is left untouched —
/// the caller is expected to follow up with
/// `flushPrefixAndDiscardRest` so that events already covered by
/// a peer slot's buffer are not double-replayed. No-op if not
/// pending or not a layer rule.
pub fn forceLayerEnter(self: *Self) void {
    if (self.state != .pending) return;
    if (!self.isLayer()) return;
    self.emitHoldDown(); // routes through layer_sink for layer rules
    self.state = .decided_hold;
}

/// Emit the first `prefix_len` buffered events through the sink,
/// then drop the entire buffer (including any suffix). Used by
/// arbitration after `forceLayerEnter` to replay events that only
/// this slot saw — the suffix is the peer's responsibility.
pub fn flushPrefixAndDiscardRest(self: *Self, prefix_len: usize) void {
    const items = self.bufferItems();
    const n = @min(prefix_len, items.len);
    if (n > 0) {
        log.info("arbitration flush: src=0x{X:0>2} replaying {d} unique-prefix event(s) (discarding {d} shared suffix)", .{ self.rule.src_usage, n, items.len - n });
    }
    for (items[0..n]) |ev| {
        self.sink(self.sink_ctx, ev);
    }
    self.buffer_len = 0;
    self.buffered_downs_len = 0;
}

fn commitTap(self: *Self) void {
    log.debug("commit tap: src=0x{X:0>2} → tap=0x{X:0>2}", .{ self.rule.src_usage, self.rule.tap_usage });
    self.emit(self.rule.tap_usage, true);
    self.emit(self.rule.tap_usage, false);
    // After tap, replay any buffered events in their original order.
    self.flushBuffer();
    self.state = .idle;
}

fn emitHoldDown(self: *Self) void {
    switch (self.rule.hold) {
        .hid_usage => |u| {
            log.debug("commit hold: src=0x{X:0>2} → hold=0x{X:0>2} down", .{ self.rule.src_usage, u });
            self.emit(u, true);
        },
        .layer => |name| {
            log.debug("commit hold: src=0x{X:0>2} → enter layer '{s}'", .{ self.rule.src_usage, name });
            if (self.layer_sink) |ls| {
                ls(self.layer_sink_ctx, name, true);
            } else {
                log.warn("layer hold for '{s}' has no layer sink — drop", .{name});
            }
        },
    }
}

fn emitHoldUp(self: *Self) void {
    switch (self.rule.hold) {
        .hid_usage => |u| {
            log.debug("commit hold: src=0x{X:0>2} → hold=0x{X:0>2} up", .{ self.rule.src_usage, u });
            self.emit(u, false);
        },
        .layer => |name| {
            log.debug("commit hold: src=0x{X:0>2} → exit layer '{s}'", .{ self.rule.src_usage, name });
            if (self.layer_sink) |ls| {
                ls(self.layer_sink_ctx, name, false);
            }
        },
    }
}

fn emit(self: *Self, usage: u16, pressed: bool) void {
    self.sink(self.sink_ctx, .{
        .usage_page = 0x07,
        .usage = usage,
        .pressed = pressed,
    });
}

fn flushBuffer(self: *Self) void {
    if (self.buffer_len > 0) {
        log.debug("flush: slot src=0x{X:0>2} replaying {d} buffered event(s)", .{ self.rule.src_usage, self.buffer_len });
    }
    for (self.bufferItems()) |ev| {
        self.sink(self.sink_ctx, ev);
    }
    self.buffer_len = 0;
    self.buffered_downs_len = 0;
}

// ─── tests ───────────────────────────────────────────────────────

const TestSink = struct {
    allocator: std.mem.Allocator,
    out: std.ArrayList(Event),

    fn init(allocator: std.mem.Allocator) TestSink {
        return .{ .allocator = allocator, .out = .empty };
    }

    fn deinit(self: *TestSink) void {
        self.out.deinit(self.allocator);
    }

    fn callback(ctx: ?*anyopaque, ev: Event) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        self.out.append(self.allocator, ev) catch unreachable;
    }
};

fn kbev(usage: u16, pressed: bool) Event {
    return .{ .usage_page = 0x07, .usage = usage, .pressed = pressed };
}

test "tap path: quick source up emits tap_down + tap_up" {
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var eng = init(.{ .src_usage = 0x39, .tap_usage = 0x29, .hold = .{ .hid_usage = 0xE0 } }, TestSink.callback, &sink);

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
    var eng = init(.{ .src_usage = 0x39, .tap_usage = 0x29, .hold = .{ .hid_usage = 0xE0 } }, TestSink.callback, &sink);

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
    var eng = init(.{ .src_usage = 0x39, .tap_usage = 0x29, .hold = .{ .hid_usage = 0xE0 } }, TestSink.callback, &sink);

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
        .hold = .{ .hid_usage = 0xE0 },
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
        .hold = .{ .hid_usage = 0xE0 },
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
        .hold = .{ .hid_usage = 0xE0 },
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
    var eng = init(.{ .src_usage = 0x39, .tap_usage = 0x29, .hold = .{ .hid_usage = 0xE0 } }, TestSink.callback, &sink);

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

test "layer hold: hold_on_other_key_press triggers layer enter+exit through layer sink" {
    const LayerEvent = struct { layer: []const u8, entering: bool };
    const LayerLog = struct {
        events: std.ArrayList(LayerEvent),

        fn cb(ctx: ?*anyopaque, layer: []const u8, entering: bool) void {
            const s: *@This() = @ptrCast(@alignCast(ctx.?));
            s.events.append(std.testing.allocator, .{ .layer = layer, .entering = entering }) catch unreachable;
        }
    };
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var ll = LayerLog{ .events = .empty };
    defer ll.events.deinit(std.testing.allocator);

    var eng = initWithLayerSink(.{
        .src_usage = 0x2C, // space
        .tap_usage = 0x2C,
        .hold = .{ .layer = "fn_layer" },
        .hold_on_other_key_press = true,
    }, TestSink.callback, &sink, LayerLog.cb, &ll);

    // space down → pending
    _ = eng.feed(kbev(0x2C, true));
    try std.testing.expectEqual(@as(usize, 0), ll.events.items.len);

    // 'h' down → hold_on_other_key_press commits the layer hold
    _ = eng.feed(kbev(0x0B, true));
    try std.testing.expectEqual(@as(usize, 1), ll.events.items.len);
    try std.testing.expectEqualStrings("fn_layer", ll.events.items[0].layer);
    try std.testing.expect(ll.events.items[0].entering);

    // 'h' up — passes through, no further layer events
    _ = eng.feed(kbev(0x0B, false));
    try std.testing.expectEqual(@as(usize, 1), ll.events.items.len);

    // space up → exit layer
    _ = eng.feed(kbev(0x2C, false));
    try std.testing.expectEqual(@as(usize, 2), ll.events.items.len);
    try std.testing.expectEqualStrings("fn_layer", ll.events.items[1].layer);
    try std.testing.expect(!ll.events.items[1].entering);

    // No HID emits at all for the layer rule's hold path.
    try std.testing.expectEqual(@as(usize, 0), sink.out.items.len);
}

test "layer hold: timer-only commit, buffered events replayed in order on tap" {
    const LayerEvent = struct { layer: []const u8, entering: bool };
    const LayerLog = struct {
        events: std.ArrayList(LayerEvent),

        fn cb(ctx: ?*anyopaque, layer: []const u8, entering: bool) void {
            const s: *@This() = @ptrCast(@alignCast(ctx.?));
            s.events.append(std.testing.allocator, .{ .layer = layer, .entering = entering }) catch unreachable;
        }
    };
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var ll = LayerLog{ .events = .empty };
    defer ll.events.deinit(std.testing.allocator);

    // Layer rule with neither permissive_hold nor hold_on_other_key_press
    // explicitly set — should still buffer non-source events because
    // layer rules always do, and replay on commit.
    var eng = initWithLayerSink(.{
        .src_usage = 0x2C, // space
        .tap_usage = 0x2C,
        .hold = .{ .layer = "fn_layer" },
        .timeout_ms = 200,
    }, TestSink.callback, &sink, LayerLog.cb, &ll);

    _ = eng.feed(kbev(0x2C, true)); // space down → pending

    // Quick prose-typing: 'h' down + 'h' up while space is briefly held.
    _ = eng.feed(kbev(0x0B, true));
    _ = eng.feed(kbev(0x0B, false));
    // No layer transition yet — just buffered.
    try std.testing.expectEqual(@as(usize, 0), ll.events.items.len);
    try std.testing.expectEqual(@as(usize, 0), sink.out.items.len);

    // Space released before timeout → tap path. Buffer replays after
    // tap_up so the kernel sees: space, h.
    _ = eng.feed(kbev(0x2C, false));
    try std.testing.expectEqual(@as(usize, 0), ll.events.items.len); // never entered layer
    try std.testing.expectEqual(@as(usize, 4), sink.out.items.len);
    try std.testing.expectEqual(@as(u32, 0x2C), sink.out.items[0].usage); // tap down (space)
    try std.testing.expect(sink.out.items[0].pressed);
    try std.testing.expectEqual(@as(u32, 0x2C), sink.out.items[1].usage); // tap up
    try std.testing.expect(!sink.out.items[1].pressed);
    try std.testing.expectEqual(@as(u32, 0x0B), sink.out.items[2].usage); // 'h' down replay
    try std.testing.expectEqual(@as(u32, 0x0B), sink.out.items[3].usage); // 'h' up replay
}

test "layer hold: timer fires after buffered events → enter layer + replay" {
    const LayerEvent = struct { layer: []const u8, entering: bool };
    const LayerLog = struct {
        events: std.ArrayList(LayerEvent),

        fn cb(ctx: ?*anyopaque, layer: []const u8, entering: bool) void {
            const s: *@This() = @ptrCast(@alignCast(ctx.?));
            s.events.append(std.testing.allocator, .{ .layer = layer, .entering = entering }) catch unreachable;
        }
    };
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var ll = LayerLog{ .events = .empty };
    defer ll.events.deinit(std.testing.allocator);

    var eng = initWithLayerSink(.{
        .src_usage = 0x2C,
        .tap_usage = 0x2C,
        .hold = .{ .layer = "fn_layer" },
    }, TestSink.callback, &sink, LayerLog.cb, &ll);

    _ = eng.feed(kbev(0x2C, true));
    _ = eng.feed(kbev(0x0B, true)); // 'h' buffered
    _ = eng.timerFired();
    // After timer: layer entered, buffer replayed.
    try std.testing.expectEqual(@as(usize, 1), ll.events.items.len);
    try std.testing.expect(ll.events.items[0].entering);
    try std.testing.expectEqual(@as(usize, 1), sink.out.items.len);
    try std.testing.expectEqual(@as(u32, 0x0B), sink.out.items[0].usage);
}

test "retro_tap: source held past timeout with no other key, on release emits tap" {
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var eng = init(.{
        .src_usage = 0x39,
        .tap_usage = 0x29,
        .hold = .{ .hid_usage = 0xE0 },
        .retro_tap = true,
    }, TestSink.callback, &sink);

    _ = eng.feed(kbev(0x39, true)); // source down → pending
    _ = eng.timerFired();             // → decided_hold, hold_down emitted
    try std.testing.expectEqual(@as(usize, 1), sink.out.items.len);
    try std.testing.expectEqual(@as(u32, 0xE0), sink.out.items[0].usage);
    try std.testing.expect(sink.out.items[0].pressed);

    _ = eng.feed(kbev(0x39, false)); // source up
    // Output: hold_up, then retro tap_down + tap_up.
    try std.testing.expectEqual(@as(usize, 4), sink.out.items.len);
    try std.testing.expectEqual(@as(u32, 0xE0), sink.out.items[1].usage); // hold up
    try std.testing.expect(!sink.out.items[1].pressed);
    try std.testing.expectEqual(@as(u32, 0x29), sink.out.items[2].usage); // tap down
    try std.testing.expect(sink.out.items[2].pressed);
    try std.testing.expectEqual(@as(u32, 0x29), sink.out.items[3].usage); // tap up
    try std.testing.expect(!sink.out.items[3].pressed);
}

test "retro_tap: other key seen during hold suppresses retro tap on release" {
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var eng = init(.{
        .src_usage = 0x39,
        .tap_usage = 0x29,
        .hold = .{ .hid_usage = 0xE0 },
        .retro_tap = true,
    }, TestSink.callback, &sink);

    _ = eng.feed(kbev(0x39, true));
    _ = eng.timerFired();
    _ = eng.feed(kbev(0x04, true));  // 'a' down — observed during hold
    _ = eng.feed(kbev(0x04, false));
    _ = eng.feed(kbev(0x39, false));

    // Output: hold_down, hold_up. No retro tap because 'a' was pressed.
    try std.testing.expectEqual(@as(usize, 2), sink.out.items.len);
    try std.testing.expectEqual(@as(u32, 0xE0), sink.out.items[0].usage);
    try std.testing.expect(sink.out.items[0].pressed);
    try std.testing.expectEqual(@as(u32, 0xE0), sink.out.items[1].usage);
    try std.testing.expect(!sink.out.items[1].pressed);
}

test "non-source events while idle: pass through, FSM untouched" {
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var eng = init(.{ .src_usage = 0x39, .tap_usage = 0x29, .hold = .{ .hid_usage = 0xE0 } }, TestSink.callback, &sink);

    const r = eng.feed(kbev(0x04, true));
    try std.testing.expectEqual(Disposition.pass, r.disposition);
    try std.testing.expectEqual(TimerAction.none, r.timer);
    try std.testing.expectEqual(@as(usize, 0), sink.out.items.len);
    try std.testing.expectEqual(State.idle, eng.state);
}

test "key released during pending: pass-through if its down was already at OS" {
    // Regression for the "single press fires N times" bug. User
    // presses 's' (slot idle, emitted directly). Then presses
    // source (slot enters pending). Then releases 's'. The old code
    // buffered the s-up — delaying it until source-up — and the OS
    // saw 's' as held for the entire pending window, autorepeating
    // it. Fix: pass-through nested-up if its matching down wasn't
    // also buffered.
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var eng = init(.{
        .src_usage = 0x2C,
        .tap_usage = 0x2C,
        .hold = .{ .layer = "fn_layer" },
        .permissive_hold = true,
    }, TestSink.callback, &sink);

    // s-down arrives idle → pass-through (caller's responsibility
    // to emit; we just verify disposition).
    const r0 = eng.feed(kbev(0x16, true));
    try std.testing.expectEqual(Disposition.pass, r0.disposition);

    // Source down → pending.
    _ = eng.feed(kbev(0x2C, true));

    // s-up arrives during pending. s-down was external (not
    // buffered) so the up must pass-through, NOT buffer.
    const r1 = eng.feed(kbev(0x16, false));
    try std.testing.expectEqual(Disposition.pass, r1.disposition);

    // Source-up before timeout → tap path. Buffer is empty.
    _ = eng.feed(kbev(0x2C, false));
    // Output: just the source tap pair. No replay of the s.
    try std.testing.expectEqual(@as(usize, 2), sink.out.items.len);
    try std.testing.expectEqual(@as(u32, 0x2C), sink.out.items[0].usage);
    try std.testing.expectEqual(@as(u32, 0x2C), sink.out.items[1].usage);
}

// ─── benchmarks ──────────────────────────────────────────────────
//
// These tests time tight loops through `feed()` to track per-event
// FSM cost. They print results via `std.debug.print` so the numbers
// land in `zig build test` output without needing extra tooling.
// `feed()` is allocation-free (BoundedArray storage is inline), so a
// counter-only sink is enough to isolate FSM time.

const CountSink = struct {
    count: usize = 0,
    fn cb(ctx: ?*anyopaque, _: Event) void {
        const self: *CountSink = @ptrCast(@alignCast(ctx.?));
        self.count += 1;
    }
};

fn benchReport(name: []const u8, total_ns: u64, events: usize) void {
    const ns_per_ev = if (events == 0) 0 else total_ns / events;
    std.debug.print(
        "[bench] {s:<48} events={d:>9} total={d:>8}us ns/event={d:>5}\n",
        .{ name, events, total_ns / std.time.ns_per_us, ns_per_ev },
    );
}

test "bench: pure-tap loop (modifier rule, no buffering)" {
    // Source down → source up → repeat. The hot path for a user
    // typing through caps_lock-as-ctrl when caps is briefly tapped
    // (no other key in flight). Exercises the .idle ⇄ .pending
    // transitions and the tap-emit path.
    var sink: CountSink = .{};
    var eng = init(
        .{ .src_usage = 0x39, .tap_usage = 0x29, .hold = .{ .hid_usage = 0xE0 } },
        CountSink.cb,
        &sink,
    );

    const iterations = 200_000;
    const t0 = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = eng.feed(kbev(0x39, true));
        _ = eng.feed(kbev(0x39, false));
    }
    const t1 = std.Io.Clock.Timestamp.now(std.testing.io, .awake); const total_ns: u64 = @intCast(t0.durationTo(t1).raw.nanoseconds);
    const events = iterations * 2;
    benchReport("pure-tap", total_ns, events);
    // Each iteration produces 2 emitted events (tap_down + tap_up).
    try std.testing.expectEqual(iterations * 2, sink.count);
}

test "bench: layer rule, fast typing burst (5 keys per hold)" {
    // Realistic fast-typing scenario for layer-hold: source down,
    // a few nested key down/up pairs (buffered), then source up
    // before timeout → commits as tap, replays the buffer. This is
    // the path a fast typist hits when rolling over a layer key
    // without actually intending to enter the layer.
    var sink: CountSink = .{};
    var eng = init(
        .{
            .src_usage = 0x2C,
            .tap_usage = 0x2C,
            .hold = .{ .layer = "fn_layer" },
            .permissive_hold = false,
        },
        CountSink.cb,
        &sink,
    );

    const iterations = 50_000;
    const inner_keys = 5;
    const t0 = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = eng.feed(kbev(0x2C, true));
        var k: u16 = 0;
        while (k < inner_keys) : (k += 1) {
            _ = eng.feed(kbev(0x04 + k, true));
            _ = eng.feed(kbev(0x04 + k, false));
        }
        _ = eng.feed(kbev(0x2C, false));
    }
    const t1 = std.Io.Clock.Timestamp.now(std.testing.io, .awake); const total_ns: u64 = @intCast(t0.durationTo(t1).raw.nanoseconds);
    const events = iterations * (2 + inner_keys * 2);
    benchReport("layer-roll-5keys", total_ns, events);
}

test "bench: hold-on-other-key-press eager commit" {
    // Source down → first other key down → eager hold commit; rest
    // of the burst flows through the .decided_hold pass-through
    // path. Source up emits hold_up. This is the cheapest realistic
    // hold path (no buffering, no timer fire from inside the test).
    var sink: CountSink = .{};
    var eng = init(
        .{
            .src_usage = 0x39,
            .tap_usage = 0x29,
            .hold = .{ .hid_usage = 0xE0 },
            .hold_on_other_key_press = true,
        },
        CountSink.cb,
        &sink,
    );

    const iterations = 50_000;
    const inner_keys = 5;
    const t0 = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = eng.feed(kbev(0x39, true));
        var k: u16 = 0;
        while (k < inner_keys) : (k += 1) {
            _ = eng.feed(kbev(0x04 + k, true));
            _ = eng.feed(kbev(0x04 + k, false));
        }
        _ = eng.feed(kbev(0x39, false));
    }
    const t1 = std.Io.Clock.Timestamp.now(std.testing.io, .awake); const total_ns: u64 = @intCast(t0.durationTo(t1).raw.nanoseconds);
    const events = iterations * (2 + inner_keys * 2);
    benchReport("hold-on-other-key-press", total_ns, events);
}

test "key pressed AND released during pending: both buffered, replayed in order" {
    // The well-behaved case (and the one we mustn't break with the
    // pass-through fix above): a nested key fully tapped inside the
    // pending window should still be buffered, so the source-tap
    // replay preserves "source-then-key" ordering.
    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var eng = init(.{
        .src_usage = 0x2C,
        .tap_usage = 0x2C,
        .hold = .{ .layer = "fn_layer" },
        .permissive_hold = true,
    }, TestSink.callback, &sink);

    _ = eng.feed(kbev(0x2C, true)); // source down
    const rd = eng.feed(kbev(0x16, true)); // s-down during pending
    try std.testing.expectEqual(Disposition.consumed, rd.disposition);
    const ru = eng.feed(kbev(0x16, false)); // s-up during pending — should buffer
    try std.testing.expectEqual(Disposition.consumed, ru.disposition);
    _ = eng.feed(kbev(0x2C, false)); // source up → tap

    // Output: source tap, then s pair.
    try std.testing.expectEqual(@as(usize, 4), sink.out.items.len);
    try std.testing.expectEqual(@as(u32, 0x2C), sink.out.items[0].usage);
    try std.testing.expect(sink.out.items[0].pressed);
    try std.testing.expectEqual(@as(u32, 0x2C), sink.out.items[1].usage);
    try std.testing.expect(!sink.out.items[1].pressed);
    try std.testing.expectEqual(@as(u32, 0x16), sink.out.items[2].usage);
    try std.testing.expect(sink.out.items[2].pressed);
    try std.testing.expectEqual(@as(u32, 0x16), sink.out.items[3].usage);
    try std.testing.expect(!sink.out.items[3].pressed);
}

test "multi-slot race: arbitration pushes layer before peer's permissive_hold commit" {
    // Repro for a user-reported bug from builtin.skhdrc: holding
    // space (→ fn_layer) AND caps (→ lctrl, permissive_hold) and
    // then tapping h would occasionally land a bare ctrl-h at the
    // OS — caps's permissive_hold fires on h-up while space is
    // still pending, and pushed the modifier replay before the
    // layer ever got pushed. With the arbitration hook wired in,
    // caps's commit calls back into the owning dispatcher, which
    // forces the pending layer slot to push its layer first; the
    // shared h-down/h-up are then emitted exactly once via caps's
    // own buffer (under the layer).
    const LayerEvent = struct { layer: []const u8, entering: bool };
    const LayerLog = struct {
        events: std.ArrayList(LayerEvent),

        fn cb(ctx: ?*anyopaque, layer: []const u8, entering: bool) void {
            const s: *@This() = @ptrCast(@alignCast(ctx.?));
            s.events.append(std.testing.allocator, .{ .layer = layer, .entering = entering }) catch unreachable;
        }
    };

    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var ll = LayerLog{ .events = .empty };
    defer ll.events.deinit(std.testing.allocator);

    // Slot 0: space → fn_layer (layer hold).
    var space_slot = initWithLayerSink(.{
        .src_usage = 0x2C, // space
        .tap_usage = 0x2C,
        .hold = .{ .layer = "fn_layer" },
        .timeout_ms = 200,
        .permissive_hold = true, // ignored for layer (by design)
        .retro_tap = true,
    }, TestSink.callback, &sink, LayerLog.cb, &ll);

    // Slot 1: caps_lock → lctrl (modifier hold, permissive_hold on).
    var caps_slot = init(.{
        .src_usage = 0x39, // caps_lock
        .tap_usage = 0x29, // escape
        .hold = .{ .hid_usage = 0xE0 }, // lctrl
        .timeout_ms = 120,
        .permissive_hold = true,
    }, TestSink.callback, &sink);

    // Stand-in for SeizeCtx's slots[]: just an array the
    // arbitration hook can iterate. We carry it through a local
    // struct so the hook ctx is type-stable.
    const Slots = struct {
        list: []*Self,

        fn hook(ctx: ?*anyopaque, committing: *Self) void {
            const sl: *@This() = @ptrCast(@alignCast(ctx.?));
            const committing_buf = committing.bufferedCount();
            for (sl.list) |peer| {
                if (peer == committing) continue;
                if (peer.state != .pending) continue;
                if (!peer.isLayer()) continue;
                const layer_len = peer.bufferedCount();
                const unique_prefix = if (layer_len > committing_buf) layer_len - committing_buf else 0;
                peer.forceLayerEnter();
                peer.flushPrefixAndDiscardRest(unique_prefix);
            }
        }
    };
    var slot_list = [_]*Self{ &space_slot, &caps_slot };
    var slots = Slots{ .list = &slot_list };
    space_slot.arbitration_hook = Slots.hook;
    space_slot.arbitration_ctx = &slots;
    caps_slot.arbitration_hook = Slots.hook;
    caps_slot.arbitration_ctx = &slots;

    // Simulate seizeInputCallback's dispatch: source events go only
    // to the owning slot; other events fan out to all slots.
    const dispatch = struct {
        fn feed(all: []*Self, ev: Event) void {
            const u: u16 = std.math.cast(u16, ev.usage) orelse 0;
            var is_source = false;
            for (all) |s| {
                if (s.rule.src_usage == u) {
                    is_source = true;
                    break;
                }
            }
            for (all) |s| {
                if (is_source and s.rule.src_usage != u) continue;
                _ = s.feed(ev);
            }
        }
    }.feed;

    // Fast user keystroke order: space ↓, caps ↓, h ↓, h ↑, caps ↑,
    // space ↑ — all inside space's 200ms timeout window (timers
    // never fire in this test).
    dispatch(&slot_list, kbev(0x2C, true));  // space down
    dispatch(&slot_list, kbev(0x39, true));  // caps down
    dispatch(&slot_list, kbev(0x0B, true));  // h down
    dispatch(&slot_list, kbev(0x0B, false)); // h up   ← caps fires, arbitration kicks in
    dispatch(&slot_list, kbev(0x39, false)); // caps up
    dispatch(&slot_list, kbev(0x2C, false)); // space up

    // Fixed expectations:
    //   layer events: enter fn_layer (from arbitration on h-up),
    //                 exit fn_layer (from space-up while in decided_hold).
    //   sink events:  caps's flushBuffer happens AFTER layer push.
    //     0: lctrl    down  ← caps emitHoldDown (after arbitration pushed layer)
    //     1: h        down  ← caps flushBuffer (only replay)
    //     2: h        up
    //     3: lctrl    up    ← caps source-up
    //   space-up no longer triggers commitTap because space was
    //   forced to decided_hold; it emits layer-pop and no HID.
    try std.testing.expectEqual(@as(usize, 2), ll.events.items.len);
    try std.testing.expectEqualStrings("fn_layer", ll.events.items[0].layer);
    try std.testing.expect(ll.events.items[0].entering);
    try std.testing.expectEqualStrings("fn_layer", ll.events.items[1].layer);
    try std.testing.expect(!ll.events.items[1].entering);

    try std.testing.expectEqual(@as(usize, 4), sink.out.items.len);
    try std.testing.expectEqual(@as(u32, 0xE0), sink.out.items[0].usage);
    try std.testing.expect(sink.out.items[0].pressed);
    try std.testing.expectEqual(@as(u32, 0x0B), sink.out.items[1].usage);
    try std.testing.expect(sink.out.items[1].pressed);
    try std.testing.expectEqual(@as(u32, 0x0B), sink.out.items[2].usage);
    try std.testing.expect(!sink.out.items[2].pressed);
    try std.testing.expectEqual(@as(u32, 0xE0), sink.out.items[3].usage);
    try std.testing.expect(!sink.out.items[3].pressed);
}

test "multi-slot race: arbitration replays layer-unique prefix before peer commit" {
    // Variant of the previous test where the user typed an extra
    // key during the space-only pending window (before caps was
    // pressed). That key is in space's buffer but NOT in caps's
    // buffer — so arbitration's "unique prefix" path replays just
    // the layer-only events under the layer, before caps's
    // modifier-down lands.
    const LayerEvent = struct { layer: []const u8, entering: bool };
    const LayerLog = struct {
        events: std.ArrayList(LayerEvent),

        fn cb(ctx: ?*anyopaque, layer: []const u8, entering: bool) void {
            const s: *@This() = @ptrCast(@alignCast(ctx.?));
            s.events.append(std.testing.allocator, .{ .layer = layer, .entering = entering }) catch unreachable;
        }
    };

    var sink = TestSink.init(std.testing.allocator);
    defer sink.deinit();
    var ll = LayerLog{ .events = .empty };
    defer ll.events.deinit(std.testing.allocator);

    var space_slot = initWithLayerSink(.{
        .src_usage = 0x2C,
        .tap_usage = 0x2C,
        .hold = .{ .layer = "fn_layer" },
        .timeout_ms = 200,
        .permissive_hold = true,
        .retro_tap = true,
    }, TestSink.callback, &sink, LayerLog.cb, &ll);

    var caps_slot = init(.{
        .src_usage = 0x39,
        .tap_usage = 0x29,
        .hold = .{ .hid_usage = 0xE0 },
        .timeout_ms = 120,
        .permissive_hold = true,
    }, TestSink.callback, &sink);

    const Slots = struct {
        list: []*Self,
        fn hook(ctx: ?*anyopaque, committing: *Self) void {
            const sl: *@This() = @ptrCast(@alignCast(ctx.?));
            const committing_buf = committing.bufferedCount();
            for (sl.list) |peer| {
                if (peer == committing) continue;
                if (peer.state != .pending) continue;
                if (!peer.isLayer()) continue;
                const layer_len = peer.bufferedCount();
                const unique_prefix = if (layer_len > committing_buf) layer_len - committing_buf else 0;
                peer.forceLayerEnter();
                peer.flushPrefixAndDiscardRest(unique_prefix);
            }
        }
    };
    var slot_list = [_]*Self{ &space_slot, &caps_slot };
    var slots = Slots{ .list = &slot_list };
    space_slot.arbitration_hook = Slots.hook;
    space_slot.arbitration_ctx = &slots;
    caps_slot.arbitration_hook = Slots.hook;
    caps_slot.arbitration_ctx = &slots;

    const dispatch = struct {
        fn feed(all: []*Self, ev: Event) void {
            const u: u16 = std.math.cast(u16, ev.usage) orelse 0;
            var is_source = false;
            for (all) |s| {
                if (s.rule.src_usage == u) {
                    is_source = true;
                    break;
                }
            }
            for (all) |s| {
                if (is_source and s.rule.src_usage != u) continue;
                _ = s.feed(ev);
            }
        }
    }.feed;

    // space ↓, a ↓, a ↑   ← these only land in space's buffer
    // caps ↓                ← caps now pending
    // h ↓, h ↑              ← both buffer these
    dispatch(&slot_list, kbev(0x2C, true));
    dispatch(&slot_list, kbev(0x04, true));  // 'a' down — space-only
    dispatch(&slot_list, kbev(0x04, false)); // 'a' up   — space-only
    dispatch(&slot_list, kbev(0x39, true));
    dispatch(&slot_list, kbev(0x0B, true));
    dispatch(&slot_list, kbev(0x0B, false)); // h up — caps's permissive_hold fires

    // Expected sink sequence on the h-up commit:
    //   layer enter (via layer_sink)
    //   a-down, a-up      (space's unique prefix — replayed under fn_layer)
    //   lctrl-down        (caps emitHoldDown)
    //   h-down, h-up      (caps flushBuffer — under fn_layer + ctrl)
    try std.testing.expectEqual(@as(usize, 1), ll.events.items.len);
    try std.testing.expect(ll.events.items[0].entering);

    try std.testing.expectEqual(@as(usize, 5), sink.out.items.len);
    try std.testing.expectEqual(@as(u32, 0x04), sink.out.items[0].usage);
    try std.testing.expect(sink.out.items[0].pressed);
    try std.testing.expectEqual(@as(u32, 0x04), sink.out.items[1].usage);
    try std.testing.expect(!sink.out.items[1].pressed);
    try std.testing.expectEqual(@as(u32, 0xE0), sink.out.items[2].usage);
    try std.testing.expect(sink.out.items[2].pressed);
    try std.testing.expectEqual(@as(u32, 0x0B), sink.out.items[3].usage);
    try std.testing.expect(sink.out.items[3].pressed);
    try std.testing.expectEqual(@as(u32, 0x0B), sink.out.items[4].usage);
    try std.testing.expect(!sink.out.items[4].pressed);
}
