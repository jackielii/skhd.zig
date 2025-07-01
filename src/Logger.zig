const std = @import("std");
const builtin = @import("builtin");

const Logger = @This();

pub const Mode = enum {
    service,
    interactive,
};

allocator: std.mem.Allocator,
mutex: std.Thread.Mutex = .{},
mode: Mode = .service,

/// Initialize logger
pub fn init(allocator: std.mem.Allocator, mode: Mode) !Logger {
    var logger = Logger{
        .allocator = allocator,
        .mode = mode,
    };

    // Log startup
    try logger.logInfo("skhd started", .{});

    return logger;
}

/// Initialize logger without startup message (for testing)
pub fn initNull(allocator: std.mem.Allocator, mode: Mode) Logger {
    return Logger{
        .allocator = allocator,
        .mode = mode,
    };
}

pub fn deinit(self: *Logger) void {
    self.logInfo("skhd shutting down", .{}) catch {};
}

/// Log info message
pub fn logInfo(self: *Logger, comptime fmt: []const u8, args: anytype) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    const timestamp = try self.getTimestamp();
    defer self.allocator.free(timestamp);

    // Format message with timestamp
    const message = try std.fmt.allocPrint(self.allocator, "[{s}] " ++ fmt ++ "\n", .{timestamp} ++ args);
    defer self.allocator.free(message);

    // Always write to stdout
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(message);
}

/// Log error message (always logged in both modes)
pub fn logError(self: *Logger, comptime fmt: []const u8, args: anytype) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    const timestamp = try self.getTimestamp();
    defer self.allocator.free(timestamp);

    // Format message with timestamp
    const message = try std.fmt.allocPrint(self.allocator, "[{s}] ERROR: " ++ fmt ++ "\n", .{timestamp} ++ args);
    defer self.allocator.free(message);

    // Always write to stderr
    const stderr = std.io.getStdErr().writer();
    try stderr.writeAll(message);
}

/// Log command execution with output
/// Note: This is currently only used for testing.
/// TODO: Implement actual command output capture in skhd.zig
pub fn logCommand(self: *Logger, command: []const u8, stdout: []const u8, stderr: []const u8) !void {
    try self.logInfo("Executing command: {s}", .{command});

    if (stdout.len > 0) {
        // Split stdout by lines and log each
        var iter = std.mem.tokenizeScalar(u8, stdout, '\n');
        while (iter.next()) |line| {
            try self.logInfo("  stdout: {s}", .{line});
        }
    }

    if (stderr.len > 0) {
        // Split stderr by lines and log each
        var iter = std.mem.tokenizeScalar(u8, stderr, '\n');
        while (iter.next()) |line| {
            try self.logError("  stderr: {s}", .{line});
        }
    }
}

/// Log debug message (only in interactive mode)
pub fn logDebug(self: *Logger, comptime fmt: []const u8, args: anytype) !void {
    if (self.mode == .interactive) {
        try self.logInfo("DEBUG: " ++ fmt, args);
    }
}

fn getTimestamp(self: *Logger) ![]u8 {
    const timestamp_ns = std.time.nanoTimestamp();
    const timestamp_s = @divFloor(timestamp_ns, std.time.ns_per_s);
    const timestamp_ms = @divFloor(@mod(timestamp_ns, std.time.ns_per_s), std.time.ns_per_ms);

    // Convert to local time
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp_s) };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const hours = day_seconds.getHoursIntoDay();
    const minutes = day_seconds.getMinutesIntoHour();
    const seconds = day_seconds.getSecondsIntoMinute();

    return std.fmt.allocPrint(self.allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        hours,
        minutes,
        seconds,
        timestamp_ms,
    });
}

test "logger creation and basic logging" {
    const allocator = std.testing.allocator;

    // Create a test logger
    var logger = try Logger.init(allocator, .interactive);
    defer logger.deinit();

    // Test various log levels
    try logger.logInfo("Test info message", .{});
    try logger.logError("Test error message", .{});
    try logger.logDebug("Test debug message", .{});

    // Test command logging
    try logger.logCommand("echo 'test'", "test output", "");
    try logger.logCommand("false", "", "command failed");
}

test "logger timestamp format" {
    const allocator = std.testing.allocator;

    var logger = Logger{
        .allocator = allocator,
        .mode = .service,
    };

    const timestamp = try logger.getTimestamp();
    defer allocator.free(timestamp);

    // Check timestamp format (YYYY-MM-DD HH:MM:SS.mmm)
    try std.testing.expect(timestamp.len >= 23);
    try std.testing.expect(timestamp[4] == '-');
    try std.testing.expect(timestamp[7] == '-');
    try std.testing.expect(timestamp[10] == ' ');
    try std.testing.expect(timestamp[13] == ':');
    try std.testing.expect(timestamp[16] == ':');
    try std.testing.expect(timestamp[19] == '.');
}
