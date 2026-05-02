//! Agent-side listener for `mode_change` push messages from the
//! grabber.
//!
//! After the agent finishes apply_rules, it can keep the IPC socket
//! open and register the fd as a CFFileDescriptor run loop source.
//! When the grabber writes a `mode_change` frame (in response to a
//! layer-hold rule committing or releasing), the run loop wakes us
//! and we read + dispatch the message inline. Same thread as the
//! CGEventTap callback, so updating `current_mode` is race-free.

const std = @import("std");
const c = @import("c.zig");
const protocol = @import("grabber_protocol");

const log = std.log.scoped(.agent_layer_listener);

/// Called when the grabber pushes a mode_change. `mode_name` is the
/// owned-by-the-buffer slice from the parsed JSON; the listener
/// borrows from a small static buffer, so handlers must copy if they
/// need to retain the name beyond their own scope. Empty string ("")
/// means "exit current layer back to default".
pub const ModeCallback = *const fn (ctx: ?*anyopaque, mode_name: []const u8) void;

/// Called once when the grabber socket goes EndOfStream (grabber
/// exited or restarted). Owner uses this to schedule a reconnect
/// timer.
pub const DisconnectCallback = *const fn (ctx: ?*anyopaque) void;

pub const Listener = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    fd: c_int,
    cb: ModeCallback,
    cb_ctx: ?*anyopaque,
    on_disconnect: ?DisconnectCallback = null,
    on_disconnect_ctx: ?*anyopaque = null,
    /// Set after we fire the disconnect callback so we don't fire it
    /// again on subsequent (no-op) callbacks. The owner is expected
    /// to deinit this listener as part of the reconnect path.
    disconnected: bool = false,
    cf_fd: c.CFFileDescriptorRef,
    runloop_source: c.CFRunLoopSourceRef,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        socket_fd: c_int,
        cb: ModeCallback,
        cb_ctx: ?*anyopaque,
    ) !*Listener {
        const self = try allocator.create(Listener);
        errdefer allocator.destroy(self);

        var ctx: c.CFFileDescriptorContext = .{
            .version = 0,
            .info = self,
            .retain = null,
            .release = null,
            .copyDescription = null,
        };
        const cf_fd = c.CFFileDescriptorCreate(
            c.kCFAllocatorDefault,
            socket_fd,
            0, // closeOnInvalidate=false: skhd owns the underlying fd
            cfFdCallback,
            &ctx,
        );
        if (cf_fd == null) return error.CFFileDescriptorCreateFailed;
        errdefer c.CFRelease(cf_fd);

        const source = c.CFFileDescriptorCreateRunLoopSource(c.kCFAllocatorDefault, cf_fd, 0);
        if (source == null) {
            c.CFFileDescriptorInvalidate(cf_fd);
            return error.RunLoopSourceCreateFailed;
        }

        self.* = .{
            .allocator = allocator,
            .io = io,
            .fd = socket_fd,
            .cb = cb,
            .cb_ctx = cb_ctx,
            .cf_fd = cf_fd,
            .runloop_source = source,
        };

        c.CFRunLoopAddSource(c.CFRunLoopGetCurrent(), source, c.kCFRunLoopDefaultMode);
        c.CFFileDescriptorEnableCallBacks(cf_fd, c.kCFFileDescriptorReadCallBack);

        log.info("layer listener active on fd={d}", .{socket_fd});
        return self;
    }

    pub fn deinit(self: *Listener) void {
        c.CFRunLoopRemoveSource(c.CFRunLoopGetCurrent(), self.runloop_source, c.kCFRunLoopDefaultMode);
        c.CFRelease(self.runloop_source);
        c.CFFileDescriptorInvalidate(self.cf_fd);
        c.CFRelease(self.cf_fd);
        self.allocator.destroy(self);
    }
};

fn cfFdCallback(
    cf_fd: c.CFFileDescriptorRef,
    callback_types: c.CFOptionFlags,
    info: ?*anyopaque,
) callconv(.c) void {
    _ = callback_types;
    const self: *Listener = @ptrCast(@alignCast(info orelse return));

    // Read one framed JSON message. Length prefix is 4 bytes; body
    // typically tens of bytes for mode_change.
    var buf: [4096]u8 = undefined;
    const stream: std.Io.net.Stream = .{ .socket = .{
        .handle = self.fd,
        .address = .{ .ip4 = .loopback(0) },
    } };
    var rbuf: [256]u8 = undefined;
    var sr = stream.reader(self.io, &rbuf);
    const n = protocol.readFrame(&sr.interface, &buf) catch |err| switch (err) {
        error.EndOfStream => {
            if (!self.disconnected) {
                self.disconnected = true;
                log.warn("grabber connection closed; layer pushes will not arrive", .{});
                if (self.on_disconnect) |cb| cb(self.on_disconnect_ctx);
            }
            return;
        },
        else => {
            log.warn("layer push read error: {s}", .{@errorName(err)});
            // Re-arm in case it was a transient fault.
            c.CFFileDescriptorEnableCallBacks(cf_fd, c.kCFFileDescriptorReadCallBack);
            return;
        },
    };

    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, buf[0..n], .{}) catch |err| {
        log.warn("layer push parse error: {s}", .{@errorName(err)});
        c.CFFileDescriptorEnableCallBacks(cf_fd, c.kCFFileDescriptorReadCallBack);
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        log.warn("layer push: not an object", .{});
        c.CFFileDescriptorEnableCallBacks(cf_fd, c.kCFFileDescriptorReadCallBack);
        return;
    }
    const obj = parsed.value.object;
    const type_val = obj.get("type") orelse {
        c.CFFileDescriptorEnableCallBacks(cf_fd, c.kCFFileDescriptorReadCallBack);
        return;
    };
    if (type_val != .string) {
        c.CFFileDescriptorEnableCallBacks(cf_fd, c.kCFFileDescriptorReadCallBack);
        return;
    }

    if (std.mem.eql(u8, type_val.string, "mode_change")) {
        const mode_val = obj.get("mode") orelse {
            log.warn("mode_change missing 'mode' field", .{});
            c.CFFileDescriptorEnableCallBacks(cf_fd, c.kCFFileDescriptorReadCallBack);
            return;
        };
        const name = if (mode_val == .string) mode_val.string else "";
        log.info("mode_change: '{s}'", .{name});
        self.cb(self.cb_ctx, name);
    } else {
        log.warn("ignoring unknown push type '{s}'", .{type_val.string});
    }

    // CFFileDescriptor read-callbacks fire once per readable
    // transition; re-arm so the next push wakes us.
    c.CFFileDescriptorEnableCallBacks(cf_fd, c.kCFFileDescriptorReadCallBack);
}
