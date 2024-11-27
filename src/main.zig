const std = @import("std");
const c = @cImport(@cInclude("Carbon/Carbon.h"));
const strForKey = @import("echo.zig").strForKey;

const echo = @import("echo.zig").echo;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        //fail test; can't try in defer as defer is executed after we return
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const alloc = gpa.allocator();
    _ = alloc;

    try echo();
    std.process.args();
}

// test {
//     std.testing.refAllDeclsRecursive(@This());
//
//     std.testing.refAllDecls(@import("parse.zig"));
// }
