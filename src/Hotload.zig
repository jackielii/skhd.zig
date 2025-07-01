const std = @import("std");
const c = @import("c.zig");

/// File system event monitoring using macOS FSEvents API.
///
/// This struct is designed to be heap-allocated because FSEvents
/// requires a stable pointer for its callbacks. Use create() to
/// allocate and destroy() to clean up.
const Hotload = @This();

// Public callback type - simplified to just take the file path
pub const Callback = *const fn (path: []const u8) void;

// Watched file entry - simplified
const WatchedFile = struct {
    absolutepath: []u8,
};

// Core fields
allocator: std.mem.Allocator,
callback: Callback,
watch_list: std.ArrayList(WatchedFile),
enabled: bool = false,

// FSEvents fields
stream: ?c.FSEventStreamRef = null,
paths: ?c.CFMutableArrayRef = null,

/// Create a new Hotload instance on the heap
/// Caller must call destroy() when done
pub fn create(allocator: std.mem.Allocator, callback: Callback) !*Hotload {
    const self = try allocator.create(Hotload);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .callback = callback,
        .watch_list = std.ArrayList(WatchedFile).init(allocator),
        .enabled = false,
        .stream = null,
        .paths = null,
    };

    return self;
}

/// Destroy a Hotload instance, cleaning up all resources
pub fn destroy(self: *Hotload) void {
    self.stop();

    // Free all watched files
    for (self.watch_list.items) |*entry| {
        self.allocator.free(entry.absolutepath);
    }
    self.watch_list.deinit();

    // Free self
    const allocator = self.allocator;
    allocator.destroy(self);
}

pub fn addFile(self: *Hotload, file_path: []const u8) !void {
    if (self.enabled) return error.AlreadyEnabled;

    // Resolve symlinks and get real path
    const real_path = try resolveSymlink(self.allocator, file_path);
    errdefer self.allocator.free(real_path);

    // Verify it's a file
    const stat = try std.fs.cwd().statFile(real_path);
    if (stat.kind != .file) {
        return error.NotAFile;
    }

    // Add to watch list
    try self.watch_list.append(.{
        .absolutepath = real_path,
    });
}

pub fn start(self: *Hotload) !void {
    if (self.enabled) return error.AlreadyEnabled;
    if (self.watch_list.items.len == 0) return error.NoFilesToWatch;

    // Create array of paths to watch
    self.paths = c.CFArrayCreateMutable(c.kCFAllocatorDefault, 0, &c.kCFTypeArrayCallBacks);
    if (self.paths == null) return error.CFArrayCreationFailed;
    errdefer {
        if (self.paths) |p| c.CFRelease(@ptrCast(p));
        self.paths = null;
    }

    // Collect unique directories to watch
    var seen_dirs = std.StringHashMap(void).init(self.allocator);
    defer seen_dirs.deinit();

    // Extract directories from file paths and add to FSEvents
    for (self.watch_list.items) |entry| {
        // Get directory from file path
        const last_slash = std.mem.lastIndexOf(u8, entry.absolutepath, "/") orelse continue;
        const directory = entry.absolutepath[0..last_slash];

        // Only add each directory once
        if (seen_dirs.contains(directory)) continue;
        try seen_dirs.put(directory, {});

        const cf_path = createCFString(directory) orelse return error.CFStringCreationFailed;
        c.CFArrayAppendValue(self.paths.?, @ptrCast(cf_path));
        c.CFRelease(@ptrCast(cf_path)); // Array retains it
    }

    // Create FSEventStream context
    var context = c.FSEventStreamContext{
        .version = 0,
        .info = @ptrCast(self),
        .retain = null,
        .release = null,
        .copyDescription = null,
    };

    // Create the event stream
    const flags = c.kFSEventStreamCreateFlagNoDefer | c.kFSEventStreamCreateFlagFileEvents;
    self.stream = c.FSEventStreamCreate(
        c.kCFAllocatorDefault,
        fseventsCallback,
        &context,
        self.paths.?,
        c.kFSEventStreamEventIdSinceNow,
        0.5, // latency in seconds
        flags,
    );

    if (self.stream == null) return error.StreamCreationFailed;
    errdefer {
        if (self.stream) |s| c.FSEventStreamRelease(s);
        self.stream = null;
    }

    // Schedule with run loop
    c.FSEventStreamScheduleWithRunLoop(
        self.stream.?,
        c.CFRunLoopGetMain(),
        c.kCFRunLoopDefaultMode,
    );

    // Start the stream
    const started = c.FSEventStreamStart(self.stream.?);
    if (started == 0) return error.StreamStartFailed;

    self.enabled = true;
}

pub fn stop(self: *Hotload) void {
    if (!self.enabled) return;

    if (self.stream) |stream| {
        c.FSEventStreamStop(stream);
        c.FSEventStreamInvalidate(stream);
        c.FSEventStreamRelease(stream);
        self.stream = null;
    }

    if (self.paths) |paths| {
        c.CFRelease(@ptrCast(paths));
        self.paths = null;
    }

    self.enabled = false;
}

// Helper functions

fn resolveSymlink(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // Try to stat the file
    const stat = std.fs.cwd().statFile(path) catch {
        // If stat fails, just return a copy of the path
        return allocator.dupe(u8, path);
    };

    // If it's not a symlink, return a copy
    if (stat.kind != .sym_link) {
        return allocator.dupe(u8, path);
    }

    // Resolve the symlink
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try std.fs.cwd().realpath(path, &buffer);
    return allocator.dupe(u8, real_path);
}

fn createCFString(str: []const u8) ?c.CFStringRef {
    return c.CFStringCreateWithBytes(
        c.kCFAllocatorDefault,
        str.ptr,
        @intCast(str.len),
        c.kCFStringEncodingUTF8,
        0, // false
    );
}

// FSEvents callback
fn fseventsCallback(
    stream: c.ConstFSEventStreamRef,
    client_info: ?*anyopaque,
    num_events: usize,
    event_paths: ?*anyopaque,
    event_flags: [*c]const c.FSEventStreamEventFlags,
    event_ids: [*c]const c.FSEventStreamEventId,
) callconv(.C) void {
    _ = stream;
    _ = event_flags;
    _ = event_ids;

    const self = @as(*Hotload, @ptrCast(@alignCast(client_info.?)));
    // FSEvents passes paths as char**, not CFStringRef*
    const paths = @as([*][*:0]const u8, @ptrCast(@alignCast(event_paths.?)));

    for (0..num_events) |i| {
        // Get the path that changed - it's already a C string!
        const changed_path = std.mem.span(paths[i]);

        // Check which watched file matches
        for (self.watch_list.items) |entry| {
            if (std.mem.eql(u8, changed_path, entry.absolutepath)) {
                self.callback(entry.absolutepath);
                break;
            }
        }
    }
}

// Test support
var test_reload_count: u32 = 0;

fn testCallback(path: []const u8) void {
    _ = path;
    test_reload_count += 1;
}

test "hotload file watching" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Reset test state
    test_reload_count = 0;

    // Create a test file with absolute path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try std.fs.cwd().realpath(".", &path_buf);
    const test_file = try std.fmt.allocPrint(allocator, "{s}/test_hotload_file.txt", .{cwd_path});
    defer allocator.free(test_file);

    try std.fs.cwd().writeFile(.{ .sub_path = "test_hotload_file.txt", .data = "Initial content\n" });

    // Create hotloader
    const hotloader = try create(allocator, testCallback);
    defer hotloader.destroy();

    // Add the test file
    try hotloader.addFile(test_file);

    // Start watching
    try hotloader.start();

    // Create a timer to modify the file and stop the run loop
    const TimerContext = struct {
        count: u32 = 0,

        fn timerCallback(timer: c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.C) void {
            _ = timer;
            const self = @as(*@This(), @ptrCast(@alignCast(info.?)));
            self.count += 1;

            // Modify the file
            const new_content = std.fmt.allocPrint(
                std.heap.c_allocator,
                "Modified content {}\n",
                .{self.count},
            ) catch return;
            defer std.heap.c_allocator.free(new_content);

            std.fs.cwd().writeFile(.{ .sub_path = "test_hotload_file.txt", .data = new_content }) catch return;

            if (self.count >= 3) {
                // Stop after 3 modifications
                c.CFRunLoopStop(c.CFRunLoopGetCurrent());
            }
        }
    };

    var timer_ctx = TimerContext{};
    var timer_context = c.CFRunLoopTimerContext{
        .version = 0,
        .info = @ptrCast(&timer_ctx),
        .retain = null,
        .release = null,
        .copyDescription = null,
    };

    const timer = c.CFRunLoopTimerCreate(
        null,
        c.CFAbsoluteTimeGetCurrent() + 0.5, // Start in 0.5 seconds
        0.5, // Repeat every 0.5 seconds
        0,
        0,
        TimerContext.timerCallback,
        &timer_context,
    );
    defer c.CFRelease(timer);

    c.CFRunLoopAddTimer(c.CFRunLoopGetCurrent(), timer, c.kCFRunLoopDefaultMode);

    // Run the event loop for a limited time
    _ = c.CFRunLoopRunInMode(c.kCFRunLoopDefaultMode, 3.0, 0); // Run for max 3 seconds

    // Clean up test file before checking
    std.fs.cwd().deleteFile("test_hotload_file.txt") catch {};

    // Verify we got at least 2 file change events (sometimes FSEvents coalesces)
    try testing.expect(test_reload_count >= 2);
}
