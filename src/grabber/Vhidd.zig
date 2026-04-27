//! Karabiner-DriverKit-VirtualHIDDevice client.
//!
//! Talks to the `vhidd_server` daemon shipped by pqrs.org's signed
//! DriverKit extension. Used by the grabber to inject HID events
//! (keyboard reports specifically — pointing/consumer reports are
//! defined for completeness but not yet wired up).
//!
//! Protocol summary (verified against
//! Karabiner-DriverKit-VirtualHIDDevice 533b4b6, July 2025):
//!
//! Transport
//!     SOCK_DGRAM Unix domain. Server listens on the lexically-last
//!     `*.sock` under `/Library/Application Support/org.pqrs/tmp/
//!     rootonly/vhidd_server/`. Clients bind their own ephemeral
//!     socket under `vhidd_client/<ns>.sock` so the server can use
//!     the sender address as the per-client key (and so responses
//!     come back via recvfrom).
//!
//! Outer envelope (pqrs::local_datagram::send_entry)
//!     [type:u8] [body…]
//!     type=0x00 → heartbeat: body = `[next_heartbeat_deadline:u32 LE]`
//!     type=0x01 → user_data:  body = vhidd protocol bytes
//!
//!     The leading type byte is stripped before the application sees
//!     a received frame.
//!
//! Inner protocol (virtual_hid_device_service)
//!     Send: [magic 'c''p'] [version:u16 LE = 5] [request:u8] [payload]
//!     Recv: [response:u8] [body…]
//!
//! Root-only: the server / client socket directories live under
//! /Library/Application Support/org.pqrs/tmp/rootonly/, which is
//! mode 0700 owned by root.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const log = std.log.scoped(.vhidd);

const protocol_version: u16 = 5;
const magic = [_]u8{ 'c', 'p' };

/// `pqrs::local_datagram::send_entry::type`.
const FrameType = enum(u8) {
    heartbeat = 0,
    user_data = 1,
};

/// `pqrs::karabiner::driverkit::virtual_hid_device_service::request`.
pub const Request = enum(u8) {
    none = 0,
    virtual_hid_keyboard_initialize = 1,
    virtual_hid_keyboard_terminate = 2,
    virtual_hid_keyboard_reset = 3,
    virtual_hid_pointing_initialize = 4,
    virtual_hid_pointing_terminate = 5,
    virtual_hid_pointing_reset = 6,
    post_keyboard_input_report = 7,
    post_consumer_input_report = 8,
    post_apple_vendor_keyboard_input_report = 9,
    post_apple_vendor_top_case_input_report = 10,
    post_generic_desktop_input_report = 11,
    post_pointing_input_report = 12,
};

/// `pqrs::karabiner::driverkit::virtual_hid_device_service::response`.
pub const Response = enum(u8) {
    none = 0,
    driver_activated = 1,
    driver_connected = 2,
    driver_version_mismatched = 3,
    virtual_hid_keyboard_ready = 4,
    virtual_hid_pointing_ready = 5,
    _,
};

/// Modifier byte layout for `keyboard_input.modifiers`. Bit values
/// match HID Usage Page 0x07 modifier semantics.
pub const Modifier = packed struct(u8) {
    left_control: bool = false,
    left_shift: bool = false,
    left_option: bool = false,
    left_command: bool = false,
    right_control: bool = false,
    right_shift: bool = false,
    right_option: bool = false,
    right_command: bool = false,
};

/// vhidd `virtual_hid_keyboard_parameters`. Byte-level layout matches
/// `__attribute__((packed))` in C++ (3 × u64 LE = 24 bytes).
pub const KeyboardParameters = struct {
    vendor_id: u64 = 0x16c0,
    product_id: u64 = 0x27db,
    /// HID Usage Page 0x07 country code; 0 = "not supported".
    country_code: u64 = 0,
};

const root_dir = "/Library/Application Support/org.pqrs/tmp/rootonly";
pub const server_socket_dir = root_dir ++ "/vhidd_server";
pub const client_socket_dir = root_dir ++ "/vhidd_client";

pub const Client = struct {
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    /// Ephemeral path we bound — needs unlink on close.
    bound_path: []u8,

    pub fn connect(allocator: std.mem.Allocator) !Client {
        const server_path = try findServerSocket(allocator);
        defer allocator.free(server_path);

        try ensureClientDir();

        const client_path = try ephemeralClientPath(allocator);
        errdefer allocator.free(client_path);

        // Stale file from a prior crash would make bind() fail with EADDRINUSE.
        posix.unlink(client_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return error.ClientSocketBindFailed,
        };

        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.DGRAM | posix.SOCK.CLOEXEC, 0);
        errdefer posix.close(fd);

        try bindUnix(fd, client_path);
        errdefer posix.unlink(client_path) catch {};

        try connectUnix(fd, server_path);

        log.info("connected: server={s} client={s}", .{ server_path, client_path });

        return .{
            .allocator = allocator,
            .fd = fd,
            .bound_path = client_path,
        };
    }

    pub fn close(self: *Client) void {
        posix.close(self.fd);
        posix.unlink(self.bound_path) catch {};
        self.allocator.free(self.bound_path);
        self.* = undefined;
    }

    /// Send a vhidd request with no payload.
    pub fn sendRequest(self: *Client, req: Request) !void {
        var buf: [16]u8 = undefined;
        const n = encodeHeader(&buf, req);
        try self.sendUserData(buf[0..n]);
    }

    /// Send a vhidd request with a fixed-size payload appended.
    pub fn sendRequestWithPayload(self: *Client, req: Request, payload: []const u8) !void {
        var buf: [1024]u8 = undefined;
        const hdr_len = encodeHeader(&buf, req);
        if (hdr_len + payload.len > buf.len) return error.PayloadTooLarge;
        @memcpy(buf[hdr_len..][0..payload.len], payload);
        try self.sendUserData(buf[0 .. hdr_len + payload.len]);
    }

    /// Send a `virtual_hid_keyboard_initialize` request with the given
    /// (vendor, product, country) tuple.
    pub fn initializeKeyboard(self: *Client, params: KeyboardParameters) !void {
        var payload: [24]u8 = undefined;
        std.mem.writeInt(u64, payload[0..8], params.vendor_id, .little);
        std.mem.writeInt(u64, payload[8..16], params.product_id, .little);
        std.mem.writeInt(u64, payload[16..24], params.country_code, .little);
        try self.sendRequestWithPayload(.virtual_hid_keyboard_initialize, &payload);
    }

    /// Send a `post_keyboard_input_report` with the 67-byte report.
    pub fn postKeyboardReport(self: *Client, modifiers: Modifier, keys: []const u16) !void {
        if (keys.len > 32) return error.TooManyKeys;
        var report: [67]u8 = @splat(0);
        report[0] = 1; // report_id
        report[1] = @bitCast(modifiers);
        report[2] = 0; // reserved
        for (keys, 0..) |k, i| {
            std.mem.writeInt(u16, report[3 + i * 2 ..][0..2], k, .little);
        }
        try self.sendRequestWithPayload(.post_keyboard_input_report, &report);
    }

    /// Reports for non-keyboard pages share an identical shape:
    ///   [u8 report_id][32 × u16 le keys] = 65 bytes
    /// Differs from the keyboard report only by report_id and the
    /// driver-side request that carries it.
    fn postKeysReport(
        self: *Client,
        request: Request,
        report_id: u8,
        keys: []const u16,
    ) !void {
        if (keys.len > 32) return error.TooManyKeys;
        var report: [65]u8 = @splat(0);
        report[0] = report_id;
        for (keys, 0..) |k, i| {
            std.mem.writeInt(u16, report[1 + i * 2 ..][0..2], k, .little);
        }
        try self.sendRequestWithPayload(request, &report);
    }

    /// Consumer page (HID 0x0C) report — volume, play/pause, mute, etc.
    /// On Apple keyboards in the default F-row mode (the "Use F1, F2…
    /// as standard function keys" setting OFF), the F-row keys emit on
    /// this page.
    pub fn postConsumerReport(self: *Client, keys: []const u16) !void {
        try self.postKeysReport(.post_consumer_input_report, 2, keys);
    }

    /// Apple Vendor Top Case page (HID 0xFF). Brightness up/down, the
    /// fn key state, and a few other Apple-specific keys.
    pub fn postAppleVendorTopCaseReport(self: *Client, keys: []const u16) !void {
        try self.postKeysReport(.post_apple_vendor_top_case_input_report, 3, keys);
    }

    /// Apple Vendor Keyboard page (HID 0xFF01). Spotlight, mission
    /// control, dictation, etc. on modern MacBooks.
    pub fn postAppleVendorKeyboardReport(self: *Client, keys: []const u16) !void {
        try self.postKeysReport(.post_apple_vendor_keyboard_input_report, 4, keys);
    }

    /// Generic Desktop page (HID 0x01). Used for `do_not_disturb`
    /// (usage 0x9B) — F6 on modern MacBooks.
    pub fn postGenericDesktopReport(self: *Client, keys: []const u16) !void {
        try self.postKeysReport(.post_generic_desktop_input_report, 7, keys);
    }

    /// Block until the given vhidd response arrives with body byte
    /// non-zero (`true`), or the timeout expires.
    ///
    /// The DriverKit boot is async: after `virtual_hid_keyboard_initialize`,
    /// the server sends `virtual_hid_keyboard_ready=false` once, then
    /// keeps sending status updates as the kernel finishes wiring up
    /// the virtual device. We're only interested in the eventual
    /// `true` arrival. Heartbeats and non-matching responses are
    /// silently consumed.
    pub fn waitForBoolTrue(self: *Client, want: Response, timeout_ms: u32) !void {
        const deadline_ms = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (true) {
            const remaining = deadline_ms - std.time.milliTimestamp();
            if (remaining <= 0) return error.Timeout;

            try setRecvTimeout(self.fd, @intCast(remaining));

            var buf: [1024]u8 = undefined;
            const n = posix.recv(self.fd, &buf, 0) catch |err| switch (err) {
                error.WouldBlock => return error.Timeout,
                else => return err,
            };
            if (n == 0) continue;

            // Wire frame: [type:u8] [body…].
            // type=0 (heartbeat) → body is `[next_heartbeat_deadline:u32 LE]`.
            // type=1 (user_data) → body is `[response:u8] [response_body…]`.
            const frame_type: FrameType = @enumFromInt(buf[0]);
            switch (frame_type) {
                .heartbeat => {
                    log.debug("recv heartbeat ({d} body bytes)", .{n - 1});
                    continue;
                },
                .user_data => {
                    if (n < 2) continue;
                    const resp: Response = @enumFromInt(buf[1]);
                    const resp_body_len = n - 2;
                    log.debug("recv response={d} body_len={d} body[0]={any}", .{
                        buf[1],
                        resp_body_len,
                        if (resp_body_len > 0) @as(?u8, buf[2]) else null,
                    });
                    if (resp == want and resp_body_len >= 1 and buf[2] != 0) {
                        return;
                    }
                    // Non-matching response (or matching but false) —
                    // loop and read again.
                },
            }
        }
    }

    fn sendUserData(self: *Client, body: []const u8) !void {
        var buf: [1024]u8 = undefined;
        if (body.len + 1 > buf.len) return error.PayloadTooLarge;
        buf[0] = @intFromEnum(FrameType.user_data);
        @memcpy(buf[1..][0..body.len], body);
        const sent = try posix.send(self.fd, buf[0 .. body.len + 1], 0);
        if (sent != body.len + 1) return error.ShortWrite;
    }
};

fn encodeHeader(buf: []u8, req: Request) usize {
    buf[0] = magic[0];
    buf[1] = magic[1];
    std.mem.writeInt(u16, buf[2..4], protocol_version, .little);
    buf[4] = @intFromEnum(req);
    return 5;
}

fn ensureClientDir() !void {
    std.fs.makeDirAbsolute(client_socket_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.AccessDenied => return error.PermissionDenied,
        else => return error.ClientSocketDirCreate,
    };
}

fn ephemeralClientPath(allocator: std.mem.Allocator) ![]u8 {
    // Karabiner uses hex-formatted nanoseconds since epoch; we match
    // that since the server doesn't care about the format, only that
    // it's unique.
    const ns = std.time.nanoTimestamp();
    return std.fmt.allocPrint(allocator, "{s}/{x}.sock", .{ client_socket_dir, @as(u128, @bitCast(ns)) });
}

/// Find the server's listening socket. Karabiner restarts produce
/// a new file (epoch-named in hex), so we glob and pick the lexically
/// last one — same algorithm Karabiner's own client uses.
fn findServerSocket(allocator: std.mem.Allocator) ![]u8 {
    var dir = std.fs.openDirAbsolute(server_socket_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.ServerSocketDirMissing,
        error.AccessDenied => return error.PermissionDenied,
        else => return err,
    };
    defer dir.close();

    var best: ?[]u8 = null;
    errdefer if (best) |p| allocator.free(p);

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .unix_domain_socket and entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sock")) continue;
        if (best) |existing| {
            if (std.mem.lessThan(u8, existing, entry.name)) {
                allocator.free(existing);
                best = try allocator.dupe(u8, entry.name);
            }
        } else {
            best = try allocator.dupe(u8, entry.name);
        }
    }

    const name = best orelse return error.ServerSocketAbsent;
    defer allocator.free(name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ server_socket_dir, name });
}

fn bindUnix(fd: posix.fd_t, path: []const u8) !void {
    var addr: posix.sockaddr.un = .{
        .family = posix.AF.UNIX,
        .path = @splat(0),
    };
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);
    posix.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) catch |err| {
        log.warn("bind {s} failed: {s}", .{ path, @errorName(err) });
        return error.ClientSocketBindFailed;
    };
}

fn connectUnix(fd: posix.fd_t, path: []const u8) !void {
    var addr: posix.sockaddr.un = .{
        .family = posix.AF.UNIX,
        .path = @splat(0),
    };
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);
    try posix.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
}

fn setRecvTimeout(fd: posix.fd_t, ms: u32) !void {
    const tv: posix.timeval = .{
        .sec = @intCast(ms / 1000),
        .usec = @intCast((ms % 1000) * 1000),
    };
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
}

test "encodeHeader writes magic + version + request" {
    var buf: [16]u8 = undefined;
    const n = encodeHeader(&buf, .virtual_hid_keyboard_initialize);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqual(@as(u8, 'c'), buf[0]);
    try std.testing.expectEqual(@as(u8, 'p'), buf[1]);
    try std.testing.expectEqual(@as(u16, 5), std.mem.readInt(u16, buf[2..4], .little));
    try std.testing.expectEqual(@as(u8, 1), buf[4]);
}

test "Modifier packs to 8 bits matching Karabiner enum" {
    const m = Modifier{ .left_control = true, .right_command = true };
    const byte: u8 = @bitCast(m);
    // bit 0 (left_control) | bit 7 (right_command) = 0b10000001 = 0x81
    try std.testing.expectEqual(@as(u8, 0x81), byte);
}
