//! Shared types and framing for the user-agent ↔ system-grabber IPC.
//!
//! Wire format: 4-byte big-endian length prefix, then a JSON object body.
//! Each message has a `type` field; payload fields depend on the type.

const std = @import("std");

/// Default socket path the grabber listens on. Override with --socket-path
/// for development runs without root.
pub const default_socket_path = "/var/run/skhd/grabber.sock";

/// Protocol version exchanged in `hello`. Bump when wire format changes
/// in a non-backwards-compatible way.
pub const protocol_version: u32 = 1;

/// Maximum size of a single framed message body (1 MiB). Guards against
/// runaway frames on a misbehaving peer.
pub const max_frame_bytes: usize = 1 * 1024 * 1024;

/// One device matcher. Both fields must match to apply the rule. If
/// omitted (null), the rule applies to all keyboards.
pub const Device = struct {
    vendor: u32,
    product: u32,
};

/// A single tap-hold remap rule. Wire-stable: don't reorder/rename
/// without bumping protocol_version.
///
/// Hold action is one of:
/// - `hold_usage > 0`: emit that HID usage on hold (modifier-style),
/// - `hold_layer != null`: switch the agent into that mode while held.
///
/// Exactly one must be set; both forms are mutually exclusive. This
/// matches `.remap … { hold: <hid-key> | <mode_name> }` in the config.
pub const Rule = struct {
    /// HID usage of the source key on usage page 0x07 (e.g. 0x39 for
    /// caps_lock).
    src_usage: u32,
    /// HID usage emitted on tap.
    tap_usage: u32,
    /// HID usage emitted on hold. Zero when `hold_layer` is set.
    hold_usage: u32 = 0,
    /// Mode name to push on hold; null when `hold_usage` is set.
    /// Owned by the wire payload's arena (parsed-from-JSON lifetime).
    hold_layer: ?[]const u8 = null,
    /// Optional device filter; null means "all keyboards".
    device: ?Device = null,
    /// Tap-hold timeout in milliseconds.
    timeout_ms: u32 = 200,
    /// QMK permissive_hold semantics.
    permissive_hold: bool = false,
    /// QMK hold_on_other_key_press semantics.
    hold_on_other_key_press: bool = false,
    /// QMK retro_tap semantics.
    retro_tap: bool = false,
};

/// Read one length-prefixed frame into `buf`. Returns the body length on
/// success. Errors if peer closed cleanly (EndOfStream) or sent a frame
/// larger than the caller-supplied buffer / `max_frame_bytes`.
pub fn readFrame(stream: anytype, buf: []u8) !usize {
    var len_bytes: [4]u8 = undefined;
    try stream.reader().readNoEof(&len_bytes);
    const len = std.mem.readInt(u32, &len_bytes, .big);
    if (len > max_frame_bytes) return error.FrameTooLarge;
    if (len > buf.len) return error.BufferTooSmall;
    try stream.reader().readNoEof(buf[0..len]);
    return @intCast(len);
}

/// Write one length-prefixed frame.
pub fn writeFrame(stream: anytype, body: []const u8) !void {
    if (body.len > max_frame_bytes) return error.FrameTooLarge;
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(body.len), .big);
    try stream.writer().writeAll(&len_bytes);
    try stream.writer().writeAll(body);
}

/// Serialize an arbitrary value to JSON and send it as one framed
/// message. Caller passes an anonymous struct literal that includes a
/// `type` field — the value is serialized verbatim so callers control
/// the wire shape.
pub fn writeMessage(stream: anytype, allocator: std.mem.Allocator, value: anytype) !void {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    try std.json.stringify(value, .{}, buf.writer());
    try writeFrame(stream, buf.items);
}

test "frame round-trip" {
    var pipe_buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&pipe_buf);

    try writeFrame(&fbs, "hello world");

    fbs.reset();
    var read_buf: [256]u8 = undefined;
    const n = try readFrame(&fbs, &read_buf);
    try std.testing.expectEqualStrings("hello world", read_buf[0..n]);
}

test "writeMessage produces parseable JSON" {
    var pipe_buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&pipe_buf);

    try writeMessage(&fbs, std.testing.allocator, .{
        .@"type" = "hello",
        .uid = @as(u32, 501),
        .version = protocol_version,
    });

    fbs.reset();
    var read_buf: [256]u8 = undefined;
    const n = try readFrame(&fbs, &read_buf);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, read_buf[0..n], .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("hello", obj.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 501), obj.get("uid").?.integer);
}
