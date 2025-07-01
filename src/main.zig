const std = @import("std");
const Skhd = @import("skhd.zig");
const synthesize = @import("synthesize.zig");
const service = @import("service.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config_file: ?[]const u8 = null;
    var verbose = false;
    var observe_mode = false;

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
        } else if (std.mem.eql(u8, args[i], "-v") or std.mem.eql(u8, args[i], "--version")) {
            std.debug.print("skhd.zig v0.1.0\n", .{});
            return;
        } else if (std.mem.eql(u8, args[i], "-k") or std.mem.eql(u8, args[i], "--key")) {
            if (i + 1 < args.len) {
                i += 1;
                try synthesize.synthesizeKey(allocator, args[i]);
                return;
            } else {
                std.debug.print("Error: --key requires a key string\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, args[i], "-t") or std.mem.eql(u8, args[i], "--text")) {
            if (i + 1 < args.len) {
                i += 1;
                try synthesize.synthesizeText(allocator, args[i]);
                return;
            } else {
                std.debug.print("Error: --text requires a text string\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, args[i], "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, args[i], "--install-service")) {
            try service.installService(allocator);
            return;
        } else if (std.mem.eql(u8, args[i], "--uninstall-service")) {
            try service.uninstallService(allocator);
            return;
        } else if (std.mem.eql(u8, args[i], "--start-service")) {
            try service.startService(allocator);
            return;
        } else if (std.mem.eql(u8, args[i], "--stop-service")) {
            try service.stopService(allocator);
            return;
        } else if (std.mem.eql(u8, args[i], "--restart-service")) {
            try service.restartService(allocator);
            return;
        } else if (std.mem.eql(u8, args[i], "-r") or std.mem.eql(u8, args[i], "--reload")) {
            try service.reloadConfig(allocator);
            return;
        }
    }

    if (observe_mode) {
        const echo = @import("echo.zig").echo;
        try echo();
        return;
    }

    // Resolve config file path
    const resolved_config_file = if (config_file) |cf|
        try allocator.dupe(u8, cf)
    else
        try getConfigFile(allocator, "skhdrc");
    defer allocator.free(resolved_config_file);

    // Check if another instance is already running
    if (!verbose) { // Only check in service mode
        if (try service.readPidFile(allocator)) |pid| {
            if (service.isProcessRunning(pid)) {
                std.debug.print("skhd is already running (PID {d})\n", .{pid});
                return;
            } else {
                // Clean up stale PID file
                service.removePidFile(allocator);
            }
        }
    }

    // Write PID file
    try service.writePidFile(allocator);
    defer service.removePidFile(allocator);

    // Initialize and run skhd
    var skhd = try Skhd.init(allocator, resolved_config_file, verbose);
    defer skhd.deinit();

    if (verbose) {
        std.debug.print("skhd: using config file: {s}\n", .{resolved_config_file});
    }

    try skhd.run();
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
        \\  -o, --observe          Observe mode - print key events
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
        \\
    , .{});
}
