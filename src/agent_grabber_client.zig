//! Agent-side client for the system-grabber IPC.
//!
//! Used by the user-agent skhd to push the caps-class subset of its
//! parsed rules to skhd-grabber. Synchronous: dial socket, hello,
//! apply_rules, bye, close. The agent calls this once at startup and
//! again after a config reload.

const std = @import("std");
const c = @import("c.zig");
const protocol = @import("grabber_protocol");

const log = std.log.scoped(.agent_grabber);

pub const Client = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,

    pub fn connect(allocator: std.mem.Allocator, socket_path: []const u8) !Client {
        const stream = std.net.connectUnixSocket(socket_path) catch |err| {
            switch (err) {
                error.FileNotFound => log.warn(
                    "grabber socket not found at {s} — is skhd-grabber installed and running?",
                    .{socket_path},
                ),
                error.ConnectionRefused => log.warn(
                    "grabber socket {s} exists but nothing is listening (stale daemon?)",
                    .{socket_path},
                ),
                error.PermissionDenied => log.warn(
                    "permission denied connecting to {s}",
                    .{socket_path},
                ),
                else => log.warn("connect to {s} failed: {s}", .{ socket_path, @errorName(err) }),
            }
            return err;
        };
        return .{ .allocator = allocator, .stream = stream };
    }

    pub fn close(self: *Client) void {
        self.stream.close();
        self.* = undefined;
    }

    /// Send `hello` and wait for the matching `ok`. Returns an error
    /// if the grabber sends back `error` instead.
    pub fn hello(self: *Client) !void {
        try protocol.writeMessage(self.stream, self.allocator, .{
            .@"type" = "hello",
            .uid = currentUid(),
            .version = protocol.protocol_version,
        });
        try expectOk(self);
    }

    /// Send the full set of caps-class rules in one apply_rules call.
    /// Replaces whatever the grabber held for this uid.
    pub fn applyRules(self: *Client, rules: []const protocol.Rule) !void {
        try protocol.writeMessage(self.stream, self.allocator, .{
            .@"type" = "apply_rules",
            .rules = rules,
        });
        try expectOk(self);
    }

    pub fn bye(self: *Client) !void {
        try protocol.writeMessage(self.stream, self.allocator, .{ .@"type" = "bye" });
        // The grabber's response to bye is ok, but we also accept the
        // peer simply closing the socket here.
        expectOk(self) catch |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        };
    }
};

fn expectOk(client: *Client) !void {
    var buf: [4096]u8 = undefined;
    const n = try protocol.readFrame(client.stream, &buf);

    var parsed = try std.json.parseFromSlice(std.json.Value, client.allocator, buf[0..n], .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.BadResponse;
    const obj = parsed.value.object;
    const t = obj.get("type") orelse return error.BadResponse;
    if (t != .string) return error.BadResponse;

    if (std.mem.eql(u8, t.string, "ok")) return;

    if (std.mem.eql(u8, t.string, "error")) {
        const code = if (obj.get("code")) |v| (if (v == .string) v.string else "?") else "?";
        const msg = if (obj.get("message")) |v| (if (v == .string) v.string else "?") else "?";
        log.warn("grabber returned error: code={s} message={s}", .{ code, msg });
        return error.GrabberError;
    }

    log.warn("grabber returned unexpected type: {s}", .{t.string});
    return error.BadResponse;
}

fn currentUid() u32 {
    return @intCast(c.getuid());
}
