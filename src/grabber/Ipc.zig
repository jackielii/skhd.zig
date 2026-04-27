//! Server-side handling of one IPC client session.
//!
//! Reads framed JSON messages, dispatches by `type`, writes back
//! `ok`/`error`/`warn` responses. Synchronous, single-threaded — D5
//! revisits this when per-uid lifecycle lands.

const std = @import("std");

const protocol = @import("grabber_protocol");

const log = std.log.scoped(.grabber_ipc);

/// Owned (deep-copied) rules and remaps from one apply_rules
/// message. Caller takes ownership and is responsible for freeing
/// each Rule's hold_layer slice plus the rules and remaps slices
/// themselves (see `freeApplied` below).
pub const AppliedRules = struct {
    uid: u32,
    rules: []protocol.Rule,
    remaps: []protocol.Remap,

    pub fn free(self: AppliedRules, allocator: std.mem.Allocator) void {
        for (self.rules) |r| {
            if (r.hold_layer) |l| allocator.free(l);
        }
        allocator.free(self.rules);
        allocator.free(self.remaps);
    }
};

/// Result of one client session.
pub const ServeResult = union(enum) {
    /// Client disconnected (sent bye, or closed) without leaving rules
    /// active. Caller should drop the connection.
    closed,
    /// Client sent apply_rules with at least one rule. Caller takes
    /// ownership of the parsed rules + remaps and the live socket;
    /// keeping the socket open lets the grabber detect agent death
    /// via EOS and tear down that subscription's rules.
    rules_applied: AppliedRules,
};

pub fn serve(allocator: std.mem.Allocator, stream: std.net.Stream) !ServeResult {
    // Per-session state: the protocol expects hello first; record the
    // client uid for subsequent messages and reject anything else
    // before hello.
    var client_uid: ?u32 = null;

    // Reasonable session-scoped buffer; rule lists in the wild won't
    // come close to this. Larger frames are rejected by readFrame's
    // BufferTooSmall guard.
    var buf: [64 * 1024]u8 = undefined;

    while (true) {
        const n = protocol.readFrame(stream, &buf) catch |err| switch (err) {
            error.EndOfStream => return .closed, // peer closed; end of session
            else => return err,
        };

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, buf[0..n], .{}) catch |err| {
            try sendError(allocator, stream, "bad_json", @errorName(err));
            return err;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            try sendError(allocator, stream, "bad_message", "expected JSON object");
            return error.BadMessage;
        }

        const obj = parsed.value.object;
        const type_val = obj.get("type") orelse {
            try sendError(allocator, stream, "bad_message", "missing 'type' field");
            return error.BadMessage;
        };
        if (type_val != .string) {
            try sendError(allocator, stream, "bad_message", "'type' must be string");
            return error.BadMessage;
        }

        const kind = type_val.string;

        if (std.mem.eql(u8, kind, "hello")) {
            client_uid = handleHello(allocator, stream, obj) catch |err| {
                return err;
            };
        } else if (std.mem.eql(u8, kind, "apply_rules")) {
            if (client_uid == null) {
                try sendError(allocator, stream, "no_hello", "send hello before apply_rules");
                return error.ProtocolViolation;
            }
            const applied = try handleApplyRules(allocator, stream, obj, client_uid.?);
            if (applied) |a| {
                // Hand the parsed rules back to the daemon along with
                // ownership of the connection. The daemon turns this
                // into a Subscription it can later GC when the socket
                // goes EOS.
                return .{ .rules_applied = a };
            }
            // Empty apply_rules clears the rule set. Continue
            // handling further messages on the same connection.
        } else if (std.mem.eql(u8, kind, "bye")) {
            try sendOk(allocator, stream);
            return .closed;
        } else {
            try sendError(allocator, stream, "unknown_type", kind);
            return error.UnknownMessageType;
        }
    }
}

fn handleHello(allocator: std.mem.Allocator, stream: std.net.Stream, obj: std.json.ObjectMap) !u32 {
    const uid_val = obj.get("uid") orelse {
        try sendError(allocator, stream, "bad_hello", "missing 'uid'");
        return error.BadHello;
    };
    if (uid_val != .integer) {
        try sendError(allocator, stream, "bad_hello", "'uid' must be integer");
        return error.BadHello;
    }
    const version_val = obj.get("version") orelse {
        try sendError(allocator, stream, "bad_hello", "missing 'version'");
        return error.BadHello;
    };
    if (version_val != .integer) {
        try sendError(allocator, stream, "bad_hello", "'version' must be integer");
        return error.BadHello;
    }
    if (version_val.integer != protocol.protocol_version) {
        try sendError(allocator, stream, "version_mismatch", "agent and grabber differ on protocol version");
        return error.VersionMismatch;
    }

    const uid: u32 = @intCast(uid_val.integer);
    log.info("hello from uid={d} version={d}", .{ uid, version_val.integer });
    try sendOk(allocator, stream);
    return uid;
}

/// Parse the apply_rules payload, deep-copy the rules+remaps so they
/// outlive the JSON arena, and return them as an `AppliedRules`. On
/// an empty payload (no rules, no remaps) returns null — the caller
/// keeps the connection open and waits for the next message.
fn handleApplyRules(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    obj: std.json.ObjectMap,
    uid: u32,
) !?AppliedRules {
    const rules_val = obj.get("rules") orelse {
        try sendError(allocator, stream, "bad_apply", "missing 'rules'");
        return error.BadApply;
    };
    if (rules_val != .array) {
        try sendError(allocator, stream, "bad_apply", "'rules' must be array");
        return error.BadApply;
    }

    const rules_json = try std.json.stringifyAlloc(allocator, rules_val, .{});
    defer allocator.free(rules_json);
    var rules_parsed = std.json.parseFromSlice([]const protocol.Rule, allocator, rules_json, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        try sendError(allocator, stream, "bad_apply", @errorName(err));
        return err;
    };
    defer rules_parsed.deinit();

    var remaps_view: []const protocol.Remap = &.{};
    var remaps_parsed: ?std.json.Parsed([]const protocol.Remap) = null;
    defer if (remaps_parsed) |*p| p.deinit();
    if (obj.get("remaps")) |remaps_val| {
        if (remaps_val != .array) {
            try sendError(allocator, stream, "bad_apply", "'remaps' must be array");
            return error.BadApply;
        }
        const remaps_json = try std.json.stringifyAlloc(allocator, remaps_val, .{});
        defer allocator.free(remaps_json);
        remaps_parsed = std.json.parseFromSlice([]const protocol.Remap, allocator, remaps_json, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            try sendError(allocator, stream, "bad_apply", @errorName(err));
            return err;
        };
        remaps_view = remaps_parsed.?.value;
    }

    log.info("apply_rules uid={d} rules={d} remaps={d}", .{ uid, rules_parsed.value.len, remaps_view.len });
    for (rules_parsed.value, 0..) |r, i| {
        log.info(
            "  rule[{d}]: src=0x{X:0>2} tap=0x{X:0>2} hold=0x{X:0>2} timeout={d}ms perm={} hokp={} retro={}",
            .{ i, r.src_usage, r.tap_usage, r.hold_usage, r.timeout_ms, r.permissive_hold, r.hold_on_other_key_press, r.retro_tap },
        );
        if (r.device) |d| {
            log.info("    device: vendor=0x{X:0>4} product=0x{X:0>4}", .{ d.vendor, d.product });
        }
    }
    for (remaps_view, 0..) |r, i| {
        log.info(
            "  remap[{d}]: src=0x{X:0>2} → dst=0x{X:0>2} on vendor=0x{X:0>4} product=0x{X:0>4}",
            .{ i, r.src_usage, r.dst_usage, r.device.vendor, r.device.product },
        );
    }

    try sendOk(allocator, stream);

    if (rules_parsed.value.len == 0 and remaps_view.len == 0) return null;

    // Deep-copy out of the JSON arena so the result outlives this
    // function. Caller frees via AppliedRules.free.
    const owned_rules = try allocator.alloc(protocol.Rule, rules_parsed.value.len);
    errdefer allocator.free(owned_rules);
    var i: usize = 0;
    errdefer while (i > 0) : (i -= 1) {
        if (owned_rules[i - 1].hold_layer) |l| allocator.free(l);
    };
    for (rules_parsed.value) |r| {
        var copy = r;
        if (r.hold_layer) |l| copy.hold_layer = try allocator.dupe(u8, l);
        owned_rules[i] = copy;
        i += 1;
    }

    const owned_remaps = try allocator.alloc(protocol.Remap, remaps_view.len);
    errdefer allocator.free(owned_remaps);
    @memcpy(owned_remaps, remaps_view);

    return .{
        .uid = uid,
        .rules = owned_rules,
        .remaps = owned_remaps,
    };
}

fn sendOk(allocator: std.mem.Allocator, stream: std.net.Stream) !void {
    try protocol.writeMessage(stream, allocator, .{ .@"type" = "ok" });
}

fn sendError(allocator: std.mem.Allocator, stream: std.net.Stream, code: []const u8, message: []const u8) !void {
    log.warn("error: code={s} message={s}", .{ code, message });
    try protocol.writeMessage(stream, allocator, .{
        .@"type" = "error",
        .code = code,
        .message = message,
    });
}
