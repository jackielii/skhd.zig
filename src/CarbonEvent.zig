const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");

const CarbonEvent = @This();
const log = std.log.scoped(.carbon_event);

allocator: std.mem.Allocator,
io: std.Io,
handler_ref: c.EventHandlerRef,
event_type: c.EventTypeSpec,
process_buffer: [512]u8 = undefined,
buffer_len: usize = 0,
mutex: std.Io.Mutex = .init,

pub fn init(allocator: std.mem.Allocator, io: std.Io) !*CarbonEvent {
    const self = try allocator.create(CarbonEvent);
    errdefer allocator.destroy(self);

    self.* = CarbonEvent{
        .allocator = allocator,
        .io = io,
        .handler_ref = undefined,
        .event_type = .{
            .eventClass = c.kEventClassApplication,
            .eventKind = c.kEventAppFrontSwitched,
        },
    };

    // GetFrontProcess + InstallApplicationEventHandler trip TCC's
    // Accessibility prompt on Tahoe for unsigned binaries — every test
    // binary that pulls Skhd.init in transitively would pop the dialog
    // on each rebuild. Skip both under tests; getProcessName() falls back
    // to "unknown", which test configs don't assert against.
    if (builtin.is_test) return self;

    // Get initial process name from the OS — no event payload yet.
    var initial_psn: c.ProcessSerialNumber = undefined;
    if (c.GetFrontProcess(&initial_psn) == c.noErr) {
        self.updateProcessNameFromPsn(&initial_psn);
    }

    // Install event handler
    const status = c.InstallApplicationEventHandler(
        carbonEventHandler,
        1,
        @ptrCast(&self.event_type),
        self,
        &self.handler_ref,
    );

    if (status != c.noErr) {
        return error.CarbonEventInitFailed;
    }

    return self;
}

pub fn deinit(self: *CarbonEvent) void {
    // Mirror the test-mode short-circuit in init() — handler was never
    // installed, so handler_ref is undefined and RemoveEventHandler
    // would dereference garbage.
    if (!builtin.is_test) {
        _ = c.RemoveEventHandler(self.handler_ref);
    }

    // Free self
    self.allocator.destroy(self);
}

/// Get the cached process name (thread-safe)
pub fn getProcessName(self: *CarbonEvent) []const u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    // Return "unknown" if we don't have a process name
    if (self.buffer_len == 0) {
        return "unknown";
    }
    return self.process_buffer[0..self.buffer_len];
}

/// Update the cached process name from a PSN (thread-safe).
fn updateProcessNameFromPsn(self: *CarbonEvent, psn: *const c.ProcessSerialNumber) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    var ref: c.CFStringRef = undefined;
    if (c.CopyProcessName(psn, &ref) != c.noErr) {
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

    const c_string_len = std.mem.len(@as([*:0]const u8, @ptrCast(&self.process_buffer)));
    self.buffer_len = c_string_len;

    for (self.process_buffer[0..self.buffer_len]) |*char| {
        char.* = std.ascii.toLower(char.*);
    }
}

/// Carbon event handler callback. The new frontmost PSN comes from the
/// event payload — calling GetFrontProcess() here is racy and can return
/// the previous front app.
fn carbonEventHandler(
    _: c.EventHandlerCallRef,
    event: c.EventRef,
    user_data: ?*anyopaque,
) callconv(.c) c.OSStatus {
    if (user_data) |data| {
        const self = @as(*CarbonEvent, @ptrCast(@alignCast(data)));
        var psn: c.ProcessSerialNumber = undefined;
        const status = c.GetEventParameter(
            event,
            c.kEventParamProcessID,
            c.typeProcessSerialNumber,
            null,
            @sizeOf(c.ProcessSerialNumber),
            null,
            &psn,
        );
        if (status != c.noErr) {
            log.err("kEventAppFrontSwitched without process PSN: status={d}", .{status});
            return status;
        }
        self.updateProcessNameFromPsn(&psn);
    }

    return c.noErr;
}
