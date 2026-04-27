//! Per-uid in-memory rule storage.
//!
//! D1 placeholder: we just stash the latest apply_rules payload per
//! uid so we can log it and confirm the IPC pipeline. D5 will wire
//! this to the active console user and enable / disable the seize
//! based on whether the active uid has any rules.

const std = @import("std");
const protocol = @import("grabber_protocol");

const log = std.log.scoped(.grabber_ruleset);

allocator: std.mem.Allocator,
per_uid: std.AutoHashMapUnmanaged(u32, Entry) = .empty,

const Self = @This();

const Entry = struct {
    rules: []protocol.Rule = &.{},
    remaps: []protocol.Remap = &.{},
};

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    var it = self.per_uid.valueIterator();
    while (it.next()) |entry_ptr| {
        freeRules(self.allocator, entry_ptr.rules);
        self.allocator.free(entry_ptr.remaps);
    }
    self.per_uid.deinit(self.allocator);
    self.* = undefined;
}

/// Replace the rule and remap lists for `uid`. Deep-copies each rule
/// so the parsed-from-JSON arena can be freed by the caller — Rule
/// has inline string slices (hold_layer) that would dangle otherwise.
/// Remaps have no inline slices, but we still allocate a fresh slice
/// so the entry owns its memory.
pub fn replaceForUid(
    self: *Self,
    uid: u32,
    rules: []const protocol.Rule,
    remaps: []const protocol.Remap,
) !void {
    if (self.per_uid.fetchRemove(uid)) |kv| {
        freeRules(self.allocator, kv.value.rules);
        self.allocator.free(kv.value.remaps);
    }
    if (rules.len == 0 and remaps.len == 0) {
        log.info("uid={d}: cleared rule set", .{uid});
        return;
    }
    const owned_rules = try self.allocator.alloc(protocol.Rule, rules.len);
    errdefer self.allocator.free(owned_rules);

    var i: usize = 0;
    errdefer while (i > 0) : (i -= 1) {
        if (owned_rules[i - 1].hold_layer) |l| self.allocator.free(l);
    };
    for (rules) |r| {
        var copy = r;
        if (r.hold_layer) |l| {
            copy.hold_layer = try self.allocator.dupe(u8, l);
        }
        owned_rules[i] = copy;
        i += 1;
    }

    const owned_remaps = try self.allocator.alloc(protocol.Remap, remaps.len);
    errdefer self.allocator.free(owned_remaps);
    @memcpy(owned_remaps, remaps);

    try self.per_uid.put(self.allocator, uid, .{
        .rules = owned_rules,
        .remaps = owned_remaps,
    });
    log.info("uid={d}: stored {d} rule(s), {d} remap(s)", .{ uid, owned_rules.len, owned_remaps.len });
}

fn freeRules(allocator: std.mem.Allocator, rules: []protocol.Rule) void {
    for (rules) |r| {
        if (r.hold_layer) |l| allocator.free(l);
    }
    allocator.free(rules);
}

pub fn rulesForUid(self: *const Self, uid: u32) []const protocol.Rule {
    if (self.per_uid.get(uid)) |entry| return entry.rules;
    return &.{};
}

pub fn remapsForUid(self: *const Self, uid: u32) []const protocol.Remap {
    if (self.per_uid.get(uid)) |entry| return entry.remaps;
    return &.{};
}

test "replace and lookup" {
    var rs = init(std.testing.allocator);
    defer rs.deinit();

    const rules = [_]protocol.Rule{
        .{ .src_usage = 0x39, .tap_usage = 0x29, .hold_usage = 0xE0 },
    };
    const remaps = [_]protocol.Remap{
        .{ .src_usage = 0x64, .dst_usage = 0x35, .device = .{ .vendor = 0x05AC, .product = 0x0342 } },
    };
    try rs.replaceForUid(501, &rules, &remaps);
    try std.testing.expectEqual(@as(usize, 1), rs.rulesForUid(501).len);
    try std.testing.expectEqual(@as(u32, 0x39), rs.rulesForUid(501)[0].src_usage);
    try std.testing.expectEqual(@as(usize, 1), rs.remapsForUid(501).len);
    try std.testing.expectEqual(@as(u32, 0x64), rs.remapsForUid(501)[0].src_usage);

    try rs.replaceForUid(501, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 0), rs.rulesForUid(501).len);
    try std.testing.expectEqual(@as(usize, 0), rs.remapsForUid(501).len);
}
