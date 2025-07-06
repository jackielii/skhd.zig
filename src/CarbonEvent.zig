const std = @import("std");
const c = @import("c.zig");

const CarbonEvent = @This();
const log = std.log.scoped(.carbon_event);

allocator: std.mem.Allocator,
handler_ref: c.EventHandlerRef,
event_type: c.EventTypeSpec,
process_buffer: [512]u8 = undefined,
buffer_len: usize = 0,
mutex: std.Thread.Mutex = .{},

pub fn init(allocator: std.mem.Allocator) !*CarbonEvent {
    const self = try allocator.create(CarbonEvent);
    errdefer allocator.destroy(self);

    self.* = CarbonEvent{
        .allocator = allocator,
        .handler_ref = undefined,
        .event_type = .{
            .eventClass = c.kEventClassApplication,
            .eventKind = c.kEventAppFrontSwitched,
        },
    };

    // Get initial process name
    try self.updateProcessName();

    // Install event handler
    const status = c.InstallApplicationEventHandler(
        carbonEventHandler,
        1,
        &self.event_type,
        self,
        &self.handler_ref,
    );

    if (status != c.noErr) {
        return error.CarbonEventInitFailed;
    }

    return self;
}

pub fn deinit(self: *CarbonEvent) void {
    // Remove event handler
    _ = c.RemoveEventHandler(self.handler_ref);

    // Free self
    self.allocator.destroy(self);
}

/// Get the cached process name (thread-safe)
pub fn getProcessName(self: *CarbonEvent) []const u8 {
    self.mutex.lock();
    defer self.mutex.unlock();
    
    // Return "unknown" if we don't have a process name
    if (self.buffer_len == 0) {
        return "unknown";
    }
    return self.process_buffer[0..self.buffer_len];
}

/// Update the cached process name (called by event handler)
fn updateProcessName(self: *CarbonEvent) !void {
    var psn: c.ProcessSerialNumber = undefined;

    self.mutex.lock();
    defer self.mutex.unlock();

    const status = c.GetFrontProcess(&psn);
    if (status != c.noErr) {
        self.buffer_len = 0;
        return;
    }

    var ref: c.CFStringRef = undefined;
    const copy_status = c.CopyProcessName(&psn, &ref);
    if (copy_status != c.noErr) {
        self.buffer_len = 0;
        return;
    }
    defer c.CFRelease(ref);

    const success = c.CFStringGetCString(
        ref,
        &self.process_buffer,
        self.process_buffer.len,
        c.kCFStringEncodingUTF8,
    );

    if (success == 0) {
        self.buffer_len = 0;
        return;
    }

    // Find actual length
    const c_string_len = std.mem.len(@as([*:0]const u8, @ptrCast(&self.process_buffer)));
    self.buffer_len = c_string_len;

    // Convert to lowercase in-place
    for (self.process_buffer[0..self.buffer_len]) |*char| {
        char.* = std.ascii.toLower(char.*);
    }
}

/// Carbon event handler callback
fn carbonEventHandler(
    _: c.EventHandlerCallRef,
    event: c.EventRef,
    user_data: ?*anyopaque,
) callconv(.c) c.OSStatus {
    _ = event;

    if (user_data) |data| {
        const self = @as(*CarbonEvent, @ptrCast(@alignCast(data)));
        self.updateProcessName() catch |err| {
            std.log.err("Failed to update process name: {}", .{err});
        };
    }

    return c.noErr;
}
