const std = @import("std");
const builtin = @import("builtin");
const track_alloc = @import("build_options").track_alloc;

const service = @import("service.zig");
const Skhd = @import("skhd.zig");
const synthesize = @import("synthesize.zig");
const TrackingAllocator = @import("TrackingAllocator.zig");

const version = std.mem.trimRight(u8, @embedFile("VERSION"), "\n\r\t ");
const log = std.log.scoped(.main);

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    // Get base allocator
    const base_gpa, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    };
    defer if (is_debug) {
        switch (debug_allocator.deinit()) {
            .ok => {},
            .leak => std.debug.print("memory leak detected\n", .{}),
        }
    };

    // Set up tracking allocator if enabled at compile time
    var tracker: if (track_alloc) TrackingAllocator else void = undefined;
    const gpa = if (comptime track_alloc) blk: {
        tracker = try TrackingAllocator.init(base_gpa);

        std.debug.print("=== Allocation Logging Enabled ===\n", .{});
        std.debug.print("All allocations and deallocations will be logged.\n\n", .{});

        break :blk tracker.allocator();
    } else base_gpa;

    defer if (comptime track_alloc) {
        std.debug.print("\n=== Final Allocation Report ===\n", .{});
        tracker.printReport(std.io.getStdErr().writer()) catch {};
        tracker.deinit();
    };

    // Parse command line arguments
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var config_file: ?[]const u8 = null;
    var verbose = false;
    var observe_mode = false;
    var hid_observe_mode = false;
    var no_hotload = false;
    var profile = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-c") or std.mem.eql(u8, args[i], "--config")) {
            if (i + 1 < args.len) {
                i += 1;
                config_file = args[i];
            } else {
                std.debug.print("Error: --config requires a file path\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, args[i], "-V") or std.mem.eql(u8, args[i], "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, args[i], "-o") or std.mem.eql(u8, args[i], "--observe")) {
            observe_mode = true;
        } else if (std.mem.eql(u8, args[i], "-O") or std.mem.eql(u8, args[i], "--observe-hid")) {
            hid_observe_mode = true;
        } else if (std.mem.eql(u8, args[i], "-v") or std.mem.eql(u8, args[i], "--version")) {
            std.debug.print("skhd.zig v{s}\n", .{version});
            return;
        } else if (std.mem.eql(u8, args[i], "-k") or std.mem.eql(u8, args[i], "--key")) {
            if (i + 1 < args.len) {
                i += 1;
                try synthesize.synthesizeKey(gpa, args[i]);
                return;
            } else {
                std.debug.print("Error: --key requires a key string\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, args[i], "-t") or std.mem.eql(u8, args[i], "--text")) {
            if (i + 1 < args.len) {
                i += 1;
                try synthesize.synthesizeText(gpa, args[i]);
                return;
            } else {
                std.debug.print("Error: --text requires a text string\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, args[i], "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, args[i], "--install-service")) {
            try service.installService(gpa);
            return;
        } else if (std.mem.eql(u8, args[i], "--uninstall-service")) {
            try service.uninstallService(gpa);
            return;
        } else if (std.mem.eql(u8, args[i], "--start-service")) {
            try service.startService(gpa);
            return;
        } else if (std.mem.eql(u8, args[i], "--stop-service")) {
            try service.stopService(gpa);
            return;
        } else if (std.mem.eql(u8, args[i], "--restart-service")) {
            try service.restartService(gpa);
            return;
        } else if (std.mem.eql(u8, args[i], "--status")) {
            try service.checkServiceStatus(gpa);
            return;
        } else if (std.mem.eql(u8, args[i], "-r") or std.mem.eql(u8, args[i], "--reload")) {
            try service.reloadConfig(gpa);
            return;
        } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--no-hotload")) {
            no_hotload = true;
        } else if (std.mem.eql(u8, args[i], "-P") or std.mem.eql(u8, args[i], "--profile")) {
            profile = true;
        }
    }

    if (observe_mode) {
        const echo = @import("echo.zig").echo;
        try echo();
        return;
    }

    if (hid_observe_mode) {
        const echoHID = @import("echo_hid.zig").echoHID;
        try echoHID();
        return;
    }

    // Resolve config file path
    const resolved_config_file = if (config_file) |cf|
        try gpa.dupe(u8, cf)
    else
        try getConfigFile(gpa, "skhdrc");
    defer gpa.free(resolved_config_file);

    // Check if another instance is already running
    if (!verbose) { // Only check in service mode
        if (try service.readPidFile(gpa)) |pid| {
            if (service.isProcessRunning(pid)) {
                std.debug.print("skhd is already running (PID {d})\n", .{pid});
                return;
            } else {
                // Clean up stale PID file
                service.removePidFile(gpa);
            }
        }
    }

    // Write PID file
    try service.writePidFile(gpa);
    defer service.removePidFile(gpa);

    // Initialize and run skhd
    var skhd = try Skhd.init(gpa, resolved_config_file, verbose, profile);
    defer skhd.deinit();

    if (verbose) {
        log.info("Using config file: {s}", .{resolved_config_file});
        if (no_hotload) {
            log.info("Hot reload disabled", .{});
        } else {
            log.info("Hot reload enabled", .{});
        }
        if (profile) {
            log.info("Profiling enabled", .{});
        }
    }

    // Pass the hotload flag to run
    skhd.run(!no_hotload) catch {};
}

/// Resolve config file path following XDG spec
/// Tries in order:
/// 1. $XDG_CONFIG_HOME/skhd/<filename>
/// 2. $HOME/.config/skhd/<filename>
/// 3. $HOME/.<filename>
pub fn getConfigFile(allocator: std.mem.Allocator, filename: []const u8) ![]const u8 {
    // Try XDG_CONFIG_HOME first
    if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg_home| {
        const path = try std.fmt.allocPrint(allocator, "{s}/skhd/{s}", .{ xdg_home, filename });
        defer allocator.free(path);

        if (fileExists(path)) {
            return try allocator.dupe(u8, path);
        }
    }

    // Try HOME/.config/skhd
    if (std.posix.getenv("HOME")) |home| {
        const config_path = try std.fmt.allocPrint(allocator, "{s}/.config/skhd/{s}", .{ home, filename });
        defer allocator.free(config_path);

        if (fileExists(config_path)) {
            return try allocator.dupe(u8, config_path);
        }

        // Try HOME/.skhdrc (dotfile in home)
        const dotfile_path = try std.fmt.allocPrint(allocator, "{s}/.{s}", .{ home, filename });
        defer allocator.free(dotfile_path);

        if (fileExists(dotfile_path)) {
            return try allocator.dupe(u8, dotfile_path);
        }
    }

    // Default to filename in current directory
    return try allocator.dupe(u8, filename);
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn printHelp() void {
    std.debug.print(
        \\skhd - Simple Hotkey Daemon for macOS
        \\
        \\Usage: skhd [options]
        \\
        \\Options:
        \\  -c, --config <file>    Specify config file (default: skhdrc)
        \\  -V, --verbose          Enable verbose output (interactive mode)
        \\  -P, --profile          Enable profiling/tracing mode
        \\  -o, --observe          Observe mode - print key events (intercepts all events)
        \\  -O, --observe-hid      Observe mode with HID - shows which device sent each key (intercepts all events)
        \\  -h, --no-hotload       Disable system for hotloading config file
        \\  -k, --key <keyspec>    Synthesize a keypress
        \\  -t, --text <text>      Synthesize text input
        \\  -r, --reload           Reload config on running instance
        \\  -v, --version          Print version
        \\      --help             Show this help message
        \\
        \\Service Management:
        \\      --install-service   Install launchd service
        \\      --uninstall-service Remove launchd service
        \\      --start-service     Start the service
        \\      --stop-service      Stop the service
        \\      --restart-service   Restart the service
        \\      --status            Check service status
        \\
    , .{});
}
