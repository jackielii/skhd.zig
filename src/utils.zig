const std = @import("std");

pub fn indentPrint(alloc: std.mem.Allocator, writer: anytype, padding: []const u8, comptime fmt: []const u8, value: anytype) !void {
    const string = try std.fmt.allocPrint(alloc, fmt, .{value});
    defer alloc.free(string);

    var parts = std.mem.splitScalar(u8, string, '\n');
    while (parts.next()) |part| {
        // var i: i32 = 0;
        // while (i < indent) {
        //     try writer.print(" ", .{});
        //     i += 1;
        // }
        try writer.print("{s}", .{padding});
        try writer.print("{s}", .{part});
        if (parts.peek() != null) {
            try writer.print("\n", .{});
        }
    }
}

test {
    const alloc = std.testing.allocator;
    var list = std.ArrayList(u8).init(alloc);
    defer list.deinit();
    const writer = list.writer();

    try indentPrint(alloc, writer, " " ** 2, "{s}", "Hello, World!");

    const expected = "  Hello, World!";
    const actual = list.items;
    try std.testing.expectEqualStrings(expected, actual);
}
