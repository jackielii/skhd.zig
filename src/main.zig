const std = @import("std");
const Skhd = @import("skhd.zig");

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

    var config_file: []const u8 = "skhdrc";
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
        } else if (std.mem.eql(u8, args[i], "--help")) {
            printHelp();
            return;
        }
    }

    if (observe_mode) {
        const echo = @import("echo.zig").echo;
        try echo();
        return;
    }

    // Initialize and run skhd
    var skhd = try Skhd.init(allocator, config_file);
    defer skhd.deinit();
    
    skhd.verbose = verbose;

    if (verbose) {
        std.debug.print("skhd: using config file: {s}\n", .{config_file});
    }

    try skhd.run();
}

fn printHelp() void {
    std.debug.print(
        \\skhd.zig - Simple Hotkey Daemon for macOS
        \\
        \\Usage: skhd [options]
        \\
        \\Options:
        \\  -c, --config <file>    Specify config file (default: skhdrc)
        \\  -V, --verbose          Enable verbose output
        \\  -o, --observe          Observe mode - print key events
        \\  -v, --version          Print version
        \\      --help             Show this help message
        \\
    , .{});
}
