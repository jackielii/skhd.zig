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
    io: std.Io,
    stream: std.Io.net.Stream,
    /// Running grabber's build version, captured from the hello-ok reply
    /// (null until `hello()` succeeds, or if the grabber is too old to
    /// send it). Owned by the client; freed in `close`.
    grabber_version: ?[]u8 = null,

    pub fn connect(allocator: std.mem.Allocator, io: std.Io, socket_path: []const u8) !Client {
        const addr = std.Io.net.UnixAddress.init(socket_path) catch |err| {
            log.warn("invalid socket path {s}: {s}", .{ socket_path, @errorName(err) });
            return err;
        };
        const stream = addr.connect(io) catch |err| {
            switch (err) {
                error.FileNotFound => log.warn(
                    "grabber socket not found at {s} — is skhd-grabber installed and running?",
                    .{socket_path},
                ),
                error.PermissionDenied, error.AccessDenied => log.warn(
                    "permission denied connecting to {s}",
                    .{socket_path},
                ),
                else => log.warn("connect to {s} failed: {s}", .{ socket_path, @errorName(err) }),
            }
            return err;
        };
        return .{ .allocator = allocator, .io = io, .stream = stream };
    }

    pub fn close(self: *Client) void {
        if (self.grabber_version) |v| self.allocator.free(v);
        self.stream.close(self.io);
        self.* = undefined;
    }

    /// Send `hello` and wait for the matching `ok`. Returns an error
    /// if the grabber sends back `error` instead.
    pub fn hello(self: *Client) !void {
        try self.send(.{
            .@"type" = "hello",
            .uid = currentUid(),
            .version = protocol.protocol_version,
        });
        try expectOk(self);
    }

    /// Send the full set of caps-class rules and colon-form remaps in
    /// one apply_rules call. Replaces whatever the grabber held for
    /// this uid. `fkeys_as_standard` mirrors NSGlobalDomain
    /// `com.apple.keyboard.fnState` so the grabber can flip its F-row
    /// translation policy without doing a privileged prefs read.
    pub fn applyRules(
        self: *Client,
        rules: []const protocol.Rule,
        remaps: []const protocol.Remap,
        fkeys_as_standard: bool,
    ) !void {
        try self.send(.{
            .@"type" = "apply_rules",
            .rules = rules,
            .remaps = remaps,
            .fkeys_as_standard = fkeys_as_standard,
        });
        try expectOk(self);
    }

    pub fn bye(self: *Client) !void {
        try self.send(.{ .@"type" = "bye" });
        // The grabber's response to bye is ok, but we also accept the
        // peer simply closing the socket here.
        expectOk(self) catch |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        };
    }

    fn send(self: *Client, value: anytype) !void {
        var buf: [4096]u8 = undefined;
        var sw = self.stream.writer(self.io, &buf);
        try protocol.writeMessage(&sw.interface, self.allocator, value);
        try sw.interface.flush();
    }
};

fn expectOk(client: *Client) !void {
    var rbuf: [4096]u8 = undefined;
    var sr = client.stream.reader(client.io, &rbuf);
    var buf: [4096]u8 = undefined;
    const n = try protocol.readFrame(&sr.interface, &buf);

    var parsed = try std.json.parseFromSlice(std.json.Value, client.allocator, buf[0..n], .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.BadResponse;
    const obj = parsed.value.object;
    const t = obj.get("type") orelse return error.BadResponse;
    if (t != .string) return error.BadResponse;

    if (std.mem.eql(u8, t.string, "ok")) {
        // Capture the grabber's reported version (parsed json is freed on
        // return, so dupe into client-owned memory).
        if (obj.get("grabber_version")) |v| {
            if (v == .string) {
                if (client.grabber_version) |old| client.allocator.free(old);
                client.grabber_version = client.allocator.dupe(u8, v.string) catch null;
            }
        }
        return;
    }

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
