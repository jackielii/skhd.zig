const std = @import("std");
const print = @import("std").debug.print;

pub fn parse(allocator: std.mem.Allocator, filename: []const u8) !void {
    print("Parsing file: {s}\n", .{filename});
    const f = try std.fs.cwd().openFile(filename, .{});
    defer f.close();

    const content = try f.readToEndAlloc(allocator, 1 << 24); // max size 16MB
    defer allocator.free(content);

    std.debug.print("Content: {s}\n", .{content});
}

const Parser = struct {
    input: []const u8,

    const Self = @This();

    pub fn init(input: []const u8) Self {
        return Self{
            .input = input,
        };
    }
};

test "Parse" {
    const allocator = std.testing.allocator;
    try parse(allocator, "/Users/jackieli/.config/skhd/skhdrc");
}
