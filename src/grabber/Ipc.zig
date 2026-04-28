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

/// Single typed envelope for everything the agent can send. All
/// payload fields are optional so the same parse handles hello /
/// apply_rules / bye in one pass — `type` selects which fields the
/// handler consults. Slices borrow from the parse arena and must be
/// deep-copied if they need to outlive the parse.
const Inbound = struct {
    @"type": []const u8,
    uid: ?u32 = null,
    version: ?u32 = null,
    rules: ?[]const protocol.Rule = null,
    remaps: ?[]const protocol.Remap = null,
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

        var parsed = std.json.parseFromSlice(Inbound, allocator, buf[0..n], .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            try sendError(allocator, stream, "bad_json", @errorName(err));
            return err;
        };
        defer parsed.deinit();

        const msg = parsed.value;
        const kind = msg.@"type";

        if (std.mem.eql(u8, kind, "hello")) {
            client_uid = try handleHello(allocator, stream, msg);
        } else if (std.mem.eql(u8, kind, "apply_rules")) {
            if (client_uid == null) {
                try sendError(allocator, stream, "no_hello", "send hello before apply_rules");
                return error.ProtocolViolation;
            }
            const applied = try handleApplyRules(allocator, stream, msg, client_uid.?);
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

fn handleHello(allocator: std.mem.Allocator, stream: std.net.Stream, msg: Inbound) !u32 {
    const uid = msg.uid orelse {
        try sendError(allocator, stream, "bad_hello", "missing 'uid'");
        return error.BadHello;
    };
    const version = msg.version orelse {
        try sendError(allocator, stream, "bad_hello", "missing 'version'");
        return error.BadHello;
    };
    if (version != protocol.protocol_version) {
        try sendError(allocator, stream, "version_mismatch", "agent and grabber differ on protocol version");
        return error.VersionMismatch;
    }
    log.info("hello from uid={d} version={d}", .{ uid, version });
    try sendOk(allocator, stream);
    return uid;
}

/// Validate the apply_rules payload, deep-copy rules+remaps so they
/// outlive the parse arena, and return them as an `AppliedRules`. On
/// an empty payload (no rules, no remaps) returns null — the caller
/// keeps the connection open and waits for the next message.
fn handleApplyRules(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    msg: Inbound,
    uid: u32,
) !?AppliedRules {
    const rules = msg.rules orelse {
        try sendError(allocator, stream, "bad_apply", "missing 'rules'");
        return error.BadApply;
    };
    const remaps = msg.remaps orelse &[_]protocol.Remap{};

    log.info("apply_rules uid={d} rules={d} remaps={d}", .{ uid, rules.len, remaps.len });
    for (rules, 0..) |r, i| {
        log.info(
            "  rule[{d}]: src=0x{X:0>2} tap=0x{X:0>2} hold=0x{X:0>2} timeout={d}ms perm={} hokp={} retro={}",
            .{ i, r.src_usage, r.tap_usage, r.hold_usage, r.timeout_ms, r.permissive_hold, r.hold_on_other_key_press, r.retro_tap },
        );
        if (r.device) |d| {
            log.info("    device: vendor=0x{X:0>4} product=0x{X:0>4}", .{ d.vendor, d.product });
        }
    }
    for (remaps, 0..) |r, i| {
        log.info(
            "  remap[{d}]: src=0x{X:0>2} → dst=0x{X:0>2} on vendor=0x{X:0>4} product=0x{X:0>4}",
            .{ i, r.src_usage, r.dst_usage, r.device.vendor, r.device.product },
        );
    }

    try sendOk(allocator, stream);

    if (rules.len == 0 and remaps.len == 0) return null;

    // Deep-copy out of the JSON arena so the result outlives this
    // function. Caller frees via AppliedRules.free.
    const owned_rules = try allocator.alloc(protocol.Rule, rules.len);
    errdefer allocator.free(owned_rules);
    var i: usize = 0;
    errdefer while (i > 0) : (i -= 1) {
        if (owned_rules[i - 1].hold_layer) |l| allocator.free(l);
    };
    for (rules) |r| {
        var copy = r;
        if (r.hold_layer) |l| copy.hold_layer = try allocator.dupe(u8, l);
        owned_rules[i] = copy;
        i += 1;
    }

    const owned_remaps = try allocator.alloc(protocol.Remap, remaps.len);
    errdefer allocator.free(owned_remaps);
    @memcpy(owned_remaps, remaps);

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
