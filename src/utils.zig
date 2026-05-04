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
