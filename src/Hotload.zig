const std = @import("std");
const posix = std.posix;
const c = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
});

const Self = @This();

allocator: std.mem.Allocator,
kq_fd: i32 = -1,
dir_fd: i32 = -1,
callback: *const fn (path: []const u8) void,
watch_path: []u8,
enabled: bool = false,
timer: ?c.CFRunLoopTimerRef = null,

pub fn init(allocator: std.mem.Allocator, callback: *const fn (path: []const u8) void) Self {
    return .{
        .allocator = allocator,
        .callback = callback,
        .watch_path = &[_]u8{},
    };
}

pub fn deinit(self: *Self) void {
    self.stop();
    if (self.watch_path.len > 0) {
        self.allocator.free(self.watch_path);
    }
}

pub fn watchFile(self: *Self, path: []const u8) !void {
    if (self.enabled) return error.AlreadyRunning;

    // Get the directory of the file to watch
    const last_slash = std.mem.lastIndexOf(u8, path, "/") orelse return error.InvalidPath;
    const dir_path = path[0..last_slash];

    // Store the directory path
    self.watch_path = try self.allocator.dupe(u8, dir_path);
    errdefer self.allocator.free(self.watch_path);

    // Create kqueue
    self.kq_fd = try posix.kqueue();
    errdefer {
        posix.close(self.kq_fd);
        self.kq_fd = -1;
    }

    // Open directory for watching
    const dir_path_z = try self.allocator.dupeZ(u8, dir_path);
    defer self.allocator.free(dir_path_z);

    self.dir_fd = try posix.open(dir_path_z, .{ .ACCMODE = .RDONLY }, 0);
    errdefer {
        posix.close(self.dir_fd);
        self.dir_fd = -1;
    }

    // Register directory for watching with kqueue
    const changes = [1]posix.Kevent{.{
        .ident = @bitCast(@as(isize, self.dir_fd)),
        .filter = std.c.EVFILT.VNODE,
        .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.CLEAR,
        .fflags = std.c.NOTE.DELETE | std.c.NOTE.WRITE | std.c.NOTE.RENAME | std.c.NOTE.REVOKE,
        .data = 0,
        .udata = 0,
    }};

    _ = try posix.kevent(self.kq_fd, &changes, &.{}, null);

    // Create CFRunLoopTimer for periodic kqueue checking
    var context = c.CFRunLoopTimerContext{
        .version = 0,
        .info = @ptrCast(self),
        .retain = null,
        .release = null,
        .copyDescription = null,
    };

    self.timer = c.CFRunLoopTimerCreate(null, c.CFAbsoluteTimeGetCurrent() + 0.5, // Start in 0.5 seconds
        0.5, // Repeat every 0.5 seconds
        0, 0, timerCallback, &context);

    if (self.timer == null) {
        return error.TimerCreationFailed;
    }

    // Add timer to current run loop
    c.CFRunLoopAddTimer(c.CFRunLoopGetCurrent(), self.timer.?, c.kCFRunLoopDefaultMode);

    self.enabled = true;
    std.log.warn("Hot reload timer started, checking every 0.5 seconds", .{});
}

pub fn stop(self: *Self) void {
    if (!self.enabled) return;

    // Remove and release timer
    if (self.timer) |timer| {
        c.CFRunLoopTimerInvalidate(timer);
        c.CFRelease(timer);
        self.timer = null;
    }

    // Clean up file descriptors
    if (self.dir_fd != -1) {
        posix.close(self.dir_fd);
        self.dir_fd = -1;
    }

    if (self.kq_fd != -1) {
        posix.close(self.kq_fd);
        self.kq_fd = -1;
    }

    self.enabled = false;
}

fn checkForEvents(self: *Self) void {
    if (!self.enabled or self.kq_fd == -1) return;

    var event_buffer: [10]posix.Kevent = undefined;
    var timeout = posix.timespec{ .sec = 0, .nsec = 0 }; // Non-blocking

    const n = posix.kevent(self.kq_fd, &.{}, &event_buffer, &timeout) catch |err| {
        std.log.warn("kqueue error: {s}", .{@errorName(err)});
        return;
    };

    if (n > 0) {
        std.log.warn("File system events detected ({d} events), triggering reload", .{n});
        // File system events detected - trigger callback
        self.callback(self.watch_path);
    }
}

fn timerCallback(timer: c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.C) void {
    _ = timer;
    if (info == null) return;
    const self: *Self = @ptrCast(@alignCast(info.?));
    self.checkForEvents();
}
