const std = @import("std");
const c = @import("c.zig");

const CarbonEvent = @This();

allocator: std.mem.Allocator,
handler_ref: c.EventHandlerRef,
event_type: c.EventTypeSpec,
process_name: []const u8,
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
        .process_name = undefined,
    };

    // Get initial process name
    self.process_name = try self.getCurrentProcessName();
    errdefer self.allocator.free(self.process_name);

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

    // Free process name
    self.allocator.free(self.process_name);

    // Free self
    self.allocator.destroy(self);
}

/// Get the cached process name (thread-safe)
pub fn getProcessName(self: *CarbonEvent) []const u8 {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.process_name;
}

/// Update the cached process name (called by event handler)
fn updateProcessName(self: *CarbonEvent) !void {
    const new_name = try self.getCurrentProcessName();

    self.mutex.lock();
    defer self.mutex.unlock();

    // Free old name and update
    self.allocator.free(self.process_name);
    self.process_name = new_name;
}

/// Get current process name (allocates memory)
fn getCurrentProcessName(self: *CarbonEvent) ![]const u8 {
    var psn: c.ProcessSerialNumber = undefined;

    const status = c.GetFrontProcess(&psn);
    if (status != c.noErr) {
        return try self.allocator.dupe(u8, "unknown");
    }

    var process_name_ref: c.CFStringRef = undefined;
    const copy_status = c.CopyProcessName(&psn, &process_name_ref);
    if (copy_status != c.noErr) {
        return try self.allocator.dupe(u8, "unknown");
    }
    defer c.CFRelease(process_name_ref);

    // Get string length
    const length = c.CFStringGetLength(process_name_ref);
    const max_size = c.CFStringGetMaximumSizeForEncoding(length, c.kCFStringEncodingUTF8) + 1;

    // Allocate buffer
    const buffer = try self.allocator.alloc(u8, @intCast(max_size));
    errdefer self.allocator.free(buffer);

    const success = c.CFStringGetCString(
        process_name_ref,
        buffer.ptr,
        @intCast(buffer.len),
        c.kCFStringEncodingUTF8,
    );

    if (success == 0) {
        self.allocator.free(buffer);
        return try self.allocator.dupe(u8, "unknown");
    }

    // Find actual length and resize
    const c_string_len = std.mem.len(@as([*:0]const u8, @ptrCast(buffer.ptr)));
    const process_name = try self.allocator.realloc(buffer, c_string_len);

    // Convert to lowercase
    for (process_name) |*char| {
        char.* = std.ascii.toLower(char.*);
    }

    return process_name;
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

