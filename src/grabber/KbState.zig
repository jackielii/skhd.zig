//! HID keyboard state aggregator.
//!
//! HID input value events arrive one transition at a time (key X
//! went down, key Y went up). The vhidd `post_keyboard_input_report`
//! protocol takes a *snapshot* — the current modifier byte plus the
//! list of all currently-held non-modifier keys.
//!
//! This struct keeps the state and emits the snapshot on demand.
//!
//! Caps-lock is treated like any other HID key; macOS's special
//! caps-lock state-machine semantics are bypassed because we're
//! injecting through the virtual HID keyboard, which is what
//! "consumes" caps_lock at the hardware level. (D4 will remap
//! caps_lock to escape/ctrl before it reaches this aggregator.)

const std = @import("std");

const Vhidd = @import("Vhidd.zig");

const log = std.log.scoped(.kbstate);

/// HID Usage Page 0x07 modifier usages.
const usage_left_control = 0xE0;
const usage_left_shift = 0xE1;
const usage_left_option = 0xE2;
const usage_left_command = 0xE3;
const usage_right_control = 0xE4;
const usage_right_shift = 0xE5;
const usage_right_option = 0xE6;
const usage_right_command = 0xE7;

/// A non-modifier key slot, kept in insertion order so reports are
/// stable. Empty slot = 0.
const max_keys = 32;

modifiers: Vhidd.Modifier = .{},
keys: [max_keys]u16 = @splat(0),

const Self = @This();

/// Apply one HID Usage Page 0x07 transition.
///
/// `usage` is the HID usage code (e.g. 0x04 = 'a', 0xE0 = left ctrl).
/// `pressed` is true on keydown, false on keyup.
///
/// Returns true if the state changed; the caller should typically
/// emit a fresh report whenever this returns true.
pub fn applyKeyboardEvent(self: *Self, usage: u16, pressed: bool) bool {
    if (modifierFor(usage)) |bit| {
        return self.applyModifier(bit, pressed);
    }
    return if (pressed) self.insertKey(usage) else self.eraseKey(usage);
}

/// Drop all held keys / modifiers (used at startup and when seize is
/// released so we don't leave phantom keys held in the virtual HID).
pub fn clear(self: *Self) void {
    self.* = .{};
}

/// Compact the keys array into a contiguous prefix and return it.
/// Mutates `self.keys` to keep slots packed at the front so the
/// returned slice is suitable for `Vhidd.Client.postKeyboardReport`.
pub fn compactedKeys(self: *Self) []const u16 {
    var write: usize = 0;
    for (self.keys) |k| {
        if (k != 0) {
            self.keys[write] = k;
            write += 1;
        }
    }
    while (write < self.keys.len) : (write += 1) {
        self.keys[write] = 0;
    }
    var n: usize = 0;
    for (self.keys) |k| {
        if (k == 0) break;
        n += 1;
    }
    return self.keys[0..n];
}

fn modifierFor(usage: u16) ?Modifier {
    return switch (usage) {
        usage_left_control => .left_control,
        usage_left_shift => .left_shift,
        usage_left_option => .left_option,
        usage_left_command => .left_command,
        usage_right_control => .right_control,
        usage_right_shift => .right_shift,
        usage_right_option => .right_option,
        usage_right_command => .right_command,
        else => null,
    };
}

const Modifier = enum {
    left_control,
    left_shift,
    left_option,
    left_command,
    right_control,
    right_shift,
    right_option,
    right_command,
};

fn applyModifier(self: *Self, m: Modifier, pressed: bool) bool {
    const before = self.modifiers;
    switch (m) {
        .left_control => self.modifiers.left_control = pressed,
        .left_shift => self.modifiers.left_shift = pressed,
        .left_option => self.modifiers.left_option = pressed,
        .left_command => self.modifiers.left_command = pressed,
        .right_control => self.modifiers.right_control = pressed,
        .right_shift => self.modifiers.right_shift = pressed,
        .right_option => self.modifiers.right_option = pressed,
        .right_command => self.modifiers.right_command = pressed,
    }
    return @as(u8, @bitCast(before)) != @as(u8, @bitCast(self.modifiers));
}

fn insertKey(self: *Self, key: u16) bool {
    for (self.keys) |k| {
        if (k == key) return false; // already held
    }
    for (&self.keys) |*k| {
        if (k.* == 0) {
            k.* = key;
            return true;
        }
    }
    log.warn("keys[] overflow — dropping insert of usage 0x{X:0>2}", .{key});
    return false;
}

fn eraseKey(self: *Self, key: u16) bool {
    var changed = false;
    for (&self.keys) |*k| {
        if (k.* == key) {
            k.* = 0;
            changed = true;
        }
    }
    return changed;
}

test "modifier press/release flips the bit" {
    var s: Self = .{};
    try std.testing.expect(s.applyKeyboardEvent(0xE0, true)); // lctrl down
    try std.testing.expect(s.modifiers.left_control);

    try std.testing.expect(s.applyKeyboardEvent(0xE0, false));
    try std.testing.expect(!s.modifiers.left_control);
}

test "key insert and erase" {
    var s: Self = .{};
    _ = s.applyKeyboardEvent(0x04, true); // 'a'
    _ = s.applyKeyboardEvent(0x05, true); // 'b'
    const held = s.compactedKeys();
    try std.testing.expectEqual(@as(usize, 2), held.len);
    try std.testing.expectEqual(@as(u16, 0x04), held[0]);
    try std.testing.expectEqual(@as(u16, 0x05), held[1]);

    _ = s.applyKeyboardEvent(0x04, false);
    const held2 = s.compactedKeys();
    try std.testing.expectEqual(@as(usize, 1), held2.len);
    try std.testing.expectEqual(@as(u16, 0x05), held2[0]);
}

test "double-press is idempotent" {
    var s: Self = .{};
    try std.testing.expect(s.applyKeyboardEvent(0x04, true));
    try std.testing.expect(!s.applyKeyboardEvent(0x04, true));
}
