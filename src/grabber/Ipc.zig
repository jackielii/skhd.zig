//! Server-side handling of one IPC client session.
//!
//! Reads framed JSON messages, dispatches by `type`, writes back
//! `ok`/`error`/`warn` responses. Synchronous, single-threaded — D5
//! revisits this when per-uid lifecycle lands.

const std = @import("std");

const protocol = @import("grabber_protocol");
const RuleSet = @import("RuleSet.zig");

const log = std.log.scoped(.grabber_ipc);

pub fn serve(allocator: std.mem.Allocator, stream: std.net.Stream, ruleset: *RuleSet) !void {
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
            error.EndOfStream => return, // peer closed; end of session
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
            try handleApplyRules(allocator, stream, obj, client_uid.?, ruleset);
        } else if (std.mem.eql(u8, kind, "bye")) {
            try sendOk(allocator, stream);
            return;
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

fn handleApplyRules(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    obj: std.json.ObjectMap,
    uid: u32,
    ruleset: *RuleSet,
) !void {
    const rules_val = obj.get("rules") orelse {
        try sendError(allocator, stream, "bad_apply", "missing 'rules'");
        return error.BadApply;
    };
    if (rules_val != .array) {
        try sendError(allocator, stream, "bad_apply", "'rules' must be array");
        return error.BadApply;
    }

    // Re-parse the rules slice into typed Rule structs so we get
    // schema validation for free.
    const rules_json = try std.json.stringifyAlloc(allocator, rules_val, .{});
    defer allocator.free(rules_json);

    var rules_parsed = std.json.parseFromSlice([]const protocol.Rule, allocator, rules_json, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        try sendError(allocator, stream, "bad_apply", @errorName(err));
        return err;
    };
    defer rules_parsed.deinit();

    try ruleset.replaceForUid(uid, rules_parsed.value);

    log.info("apply_rules uid={d} count={d}", .{ uid, rules_parsed.value.len });
    for (rules_parsed.value, 0..) |r, i| {
        log.info(
            "  rule[{d}]: src=0x{X:0>2} tap=0x{X:0>2} hold=0x{X:0>2} timeout={d}ms perm={} hokp={} retro={}",
            .{
                i,
                r.src_usage,
                r.tap_usage,
                r.hold_usage,
                r.timeout_ms,
                r.permissive_hold,
                r.hold_on_other_key_press,
                r.retro_tap,
            },
        );
        if (r.device) |d| {
            log.info("    device: vendor=0x{X:0>4} product=0x{X:0>4}", .{ d.vendor, d.product });
        }
    }

    try sendOk(allocator, stream);
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
