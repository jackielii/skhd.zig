// struct mode
// {
//     char *name;
//     char *command;
//     bool capture;
//     bool initialized;
//     struct table hotkey_map;
// };
const std = @import("std");
const Hotkey = @import("Hotkey.zig");
const utils = @import("utils.zig");

const Mode = @This();
const log = std.log.scoped(.mode);

allocator: std.mem.Allocator,
name: []const u8,
command: ?[:0]const u8 = null,
capture: bool = false,
initialized: bool = false,
hotkey_map: Hotkey.HotkeyMap = .empty,

pub fn init(allocator: std.mem.Allocator, name: []const u8) !Mode {
    return Mode{
        .allocator = allocator,
        .name = try allocator.dupe(u8, name),
        .capture = false,
        .initialized = true,
    };
}

pub fn deinit(self: *Mode) void {
    self.allocator.free(self.name);
    if (self.command) |cmd| self.allocator.free(cmd);
    self.hotkey_map.deinit(self.allocator);
    self.* = undefined;
}

pub fn set_command(self: *Mode, command: []const u8) !void {
    if (self.command) |cmd| self.allocator.free(cmd);
    self.command = try self.allocator.dupeZ(u8, command);
}

pub fn format(self: Mode, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("Mode{");
    try writer.print("\n  name: {s}", .{self.name});
    try writer.print("\n  command: {?s}", .{self.command});
    try writer.print("\n  capture: {}", .{self.capture});
    try writer.print("\n  initialized: {}", .{self.initialized});
    try writer.writeAll("\n  hotkey_map: {\n");
    {
        var it = self.hotkey_map.iterator();
        while (it.next()) |kv| {
            utils.indentPrint(self.allocator, writer, "    ", "{f}", kv.key_ptr.*) catch return error.WriteFailed;
        }
    }
    try writer.writeAll("\n  }");
    try writer.writeAll("\n}");
}

pub fn add_hotkey(self: *Mode, hotkey: *Hotkey) !void {
    // Two hotkeys conflict iff one's chord list prefixes the other's AND
    // their process scopes overlap. Chords compare with per-family overlap
    // semantics, so "prefixes" covers every pair a single physical press
    // could match both of. That guarantees at most one hotkey matches any
    // (mode, prefix, process) — the property PrefixLookupContext relies on
    // to make probe order unobservable.
    //
    // A bare hotkey is wildcard-scoped, so scopes always overlap for it and
    // today's duplicate detection is unchanged.
    var it = self.hotkey_map.iterator();
    while (it.next()) |entry| {
        const existing = entry.key_ptr.*;
        if (!Hotkey.onePrefixesOther(existing, hotkey)) continue;
        // HotkeyMap keys on chords alone, so eql-equal hotkeys cannot coexist
        // regardless of process scope — put() would silently drop one.
        if (Hotkey.eql(existing, hotkey)) return error.DuplicateHotkeyInMode;
        if (!Hotkey.processScopesOverlap(existing, hotkey)) continue;
        if (existing.chords.len == hotkey.chords.len) return error.DuplicateHotkeyInMode;

        // Unequal lengths: the shorter is the longer's fallback. The runtime
        // defers it while the longer one is reachable and fires it if the
        // sequence doesn't complete, so this is no longer ambiguous.
        //
        // Except when the shorter one is `~`/`->`: both mean "let the key
        // reach the app", but a prefix chord is consumed the instant it
        // arrives, so by the time the fallback runs there is no event left to
        // deliver. Unrepresentable, not merely awkward.
        const shorter = if (existing.chords.len < hotkey.chords.len) existing else hotkey;
        if (shorter.passthrough or shorter.hasUnboundAction()) {
            return error.PassthroughPrefixNotAllowed;
        }
    }

    try self.hotkey_map.put(self.allocator, hotkey, {});
}

test "init" {
    const alloc = std.testing.allocator;
    var mode = try Mode.init(alloc, "default");
    defer mode.deinit();

    var key = try Hotkey.create(alloc, &.{.{ .flags = .{}, .key = 0 }});
    defer key.destroy();
    try key.add_process_command("notepad.exe", "echo notepad");
    try key.add_mode(&mode);
    try mode.add_hotkey(key);

    // const string = try std.fmt.allocPrint(alloc, "{}", .{mode});
    // defer alloc.free(string);
    // std.debug.print("{s}\n", .{string});
}
