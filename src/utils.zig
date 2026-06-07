const std = @import("std");

/// `std.posix.getenv` was removed in Zig 0.16. The 0.16 alternative is
/// `std.process.Init.environ_map.get(...)`, but that map is documented
/// "Not threadsafe" — and we read env vars from threads (the carbon
/// event handler thread, the hotload thread). libc's `getenv(3)` is
/// thread-safe for reads on POSIX systems, so we route through it
/// directly here. This is the one libc shim we keep; everything else
/// uses the proper `std.Io.*` APIs.
pub fn getenv(name: [:0]const u8) ?[]const u8 {
    const ptr = std.c.getenv(name.ptr) orelse return null;
    return std.mem.sliceTo(ptr, 0);
}

/// Resolve the skhd config file path, trying (in order): `$XDG_CONFIG_HOME/skhd/<filename>`,
/// `$HOME/.config/skhd/<filename>`, `$HOME/.<filename>`, and finally `<filename>` in the
/// current directory. Returns an owned path the caller must free.
pub fn getConfigFile(allocator: std.mem.Allocator, io: std.Io, filename: []const u8) ![]const u8 {
    // Try XDG_CONFIG_HOME first
    if (getenv("XDG_CONFIG_HOME")) |xdg_home| {
        const path = try std.fmt.allocPrint(allocator, "{s}/skhd/{s}", .{ xdg_home, filename });
        defer allocator.free(path);

        if (fileExists(io, path)) {
            return try allocator.dupe(u8, path);
        }
    }

    // Try HOME/.config/skhd
    if (getenv("HOME")) |home| {
        const config_path = try std.fmt.allocPrint(allocator, "{s}/.config/skhd/{s}", .{ home, filename });
        defer allocator.free(config_path);

        if (fileExists(io, config_path)) {
            return try allocator.dupe(u8, config_path);
        }

        // Try HOME/.skhdrc (dotfile in home)
        const dotfile_path = try std.fmt.allocPrint(allocator, "{s}/.{s}", .{ home, filename });
        defer allocator.free(dotfile_path);

        if (fileExists(io, dotfile_path)) {
            return try allocator.dupe(u8, dotfile_path);
        }
    }

    // Default to filename in current directory
    return try allocator.dupe(u8, filename);
}

pub fn fileExists(io: std.Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    } else {
        std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    }
    return true;
}

pub fn indentPrint(alloc: std.mem.Allocator, writer: anytype, padding: []const u8, comptime fmt: []const u8, value: anytype) !void {
    const string = try std.fmt.allocPrint(alloc, fmt, .{value});
    defer alloc.free(string);

    var parts = std.mem.splitScalar(u8, string, '\n');
    while (parts.next()) |part| {
        try writer.print("{s}", .{padding});
        try writer.print("{s}", .{part});
        if (parts.peek() != null) {
            try writer.print("\n", .{});
        }
    }
}

test indentPrint {
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    try indentPrint(alloc, &aw.writer, " " ** 2, "{s}", "Hello, World!");

    try std.testing.expectEqualStrings("  Hello, World!", aw.written());
}
