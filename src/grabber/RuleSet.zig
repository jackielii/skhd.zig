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
per_uid: std.AutoHashMapUnmanaged(u32, []protocol.Rule) = .empty,

const Self = @This();

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    var it = self.per_uid.valueIterator();
    while (it.next()) |rules_ptr| {
        self.allocator.free(rules_ptr.*);
    }
    self.per_uid.deinit(self.allocator);
    self.* = undefined;
}

/// Replace the rule list for `uid`. The grabber owns its own copy of
/// the rules so the parsed-from-JSON arena can be freed.
pub fn replaceForUid(self: *Self, uid: u32, rules: []const protocol.Rule) !void {
    if (self.per_uid.fetchRemove(uid)) |kv| {
        self.allocator.free(kv.value);
    }
    if (rules.len == 0) {
        log.info("uid={d}: cleared rule set", .{uid});
        return;
    }
    const owned = try self.allocator.dupe(protocol.Rule, rules);
    try self.per_uid.put(self.allocator, uid, owned);
    log.info("uid={d}: stored {d} rule(s)", .{ uid, owned.len });
}

pub fn rulesForUid(self: *const Self, uid: u32) []const protocol.Rule {
    if (self.per_uid.get(uid)) |rules| return rules;
    return &.{};
}

test "replace and lookup" {
    var rs = init(std.testing.allocator);
    defer rs.deinit();

    const rules = [_]protocol.Rule{
        .{ .src_usage = 0x39, .tap_usage = 0x29, .hold_usage = 0xE0 },
    };
    try rs.replaceForUid(501, &rules);
    try std.testing.expectEqual(@as(usize, 1), rs.rulesForUid(501).len);
    try std.testing.expectEqual(@as(u32, 0x39), rs.rulesForUid(501)[0].src_usage);

    try rs.replaceForUid(501, &.{});
    try std.testing.expectEqual(@as(usize, 0), rs.rulesForUid(501).len);
}
