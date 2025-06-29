// struct hotkey
// {
//     uint32_t flags;
//     uint32_t key;
//     char **process_name;
//     char **command;
//     char *wildcard_command;
//     struct mode **mode_list;
//     struct hotkey *forwarded_hotkey;
// };

const std = @import("std");
const Hotkey = @This();
const Mode = @import("Mode.zig");
const utils = @import("./utils.zig");
const ModifierFlag = @import("./Keycodes.zig").ModifierFlag;

pub const HotkeyMap = std.ArrayHashMapUnmanaged(*Hotkey, void, struct {
    pub fn hash(self: @This(), key: *Hotkey) u32 {
        _ = self;
        return @as(u32, @bitCast(key.flags)) ^ key.key;
    }
    pub fn eql(self: @This(), a: *Hotkey, b: *Hotkey, _: anytype) bool {
        _ = self;
        return Hotkey.eql(a, b);
    }
}, false);

pub const KeyPress = struct {
    flags: ModifierFlag,
    key: u32,
};

pub fn eql(a: *Hotkey, b: *Hotkey) bool {
    // Implement left/right modifier comparison logic like original skhd
    return compareLRMod(a, b, .alt) and
           compareLRMod(a, b, .cmd) and
           compareLRMod(a, b, .control) and
           compareLRMod(a, b, .shift) and
           compareFn(a, b) and
           compareNX(a, b) and
           a.key == b.key;
}

fn compareLRMod(a: *Hotkey, b: *Hotkey, comptime mod: enum { alt, cmd, control, shift }) bool {
    const general_field = switch (mod) {
        .alt => "alt",
        .cmd => "cmd", 
        .control => "control",
        .shift => "shift",
    };
    const left_field = switch (mod) {
        .alt => "lalt",
        .cmd => "lcmd",
        .control => "lcontrol", 
        .shift => "lshift",
    };
    const right_field = switch (mod) {
        .alt => "ralt",
        .cmd => "rcmd",
        .control => "rcontrol",
        .shift => "rshift",
    };
    
    const a_general = @field(a.flags, general_field);
    const a_left = @field(a.flags, left_field);
    const a_right = @field(a.flags, right_field);
    
    const b_general = @field(b.flags, general_field);
    const b_left = @field(b.flags, left_field);
    const b_right = @field(b.flags, right_field);
    
    // If hotkey A has general modifier, it matches any of general/left/right in B
    if (a_general) {
        return b_left or b_right or b_general;
    }
    
    // Otherwise, each specific modifier must match exactly
    return a_left == b_left and a_right == b_right and a_general == b_general;
}

fn compareFn(a: *Hotkey, b: *Hotkey) bool {
    return a.flags.@"fn" == b.flags.@"fn";
}

fn compareNX(a: *Hotkey, b: *Hotkey) bool {
    return a.flags.nx == b.flags.nx;
}

const processCommand = union(enum) {
    command: []const u8,
    forwarded: KeyPress,
    unbound: void,
};

allocator: std.mem.Allocator,
flags: ModifierFlag = undefined,
key: u32 = undefined,
process_names: std.ArrayListUnmanaged([]const u8) = .empty,
commands: std.ArrayListUnmanaged(processCommand) = .empty,
wildcard_command: ?processCommand = null,
mode_list: std.AutoArrayHashMap(*Mode, void),

pub fn destroy(self: *Hotkey) void {
    {
        for (self.process_names.items) |name| self.allocator.free(name);
        self.process_names.deinit(self.allocator);
    }

    {
        for (self.commands.items) |cmd| {
            switch (cmd) {
                .command => self.allocator.free(cmd.command),
                else => {},
            }
        }
        self.commands.deinit(self.allocator);
    }

    self.deinit_wildcard_command();
    self.mode_list.deinit();
    self.allocator.destroy(self);
}

pub fn create(allocator: std.mem.Allocator) !*Hotkey {
    const hotkey = try allocator.create(Hotkey);
    hotkey.* = .{
        .allocator = allocator,
        .flags = ModifierFlag{},
        .key = 0,
        .process_names = .empty,
        .commands = .empty,
        .wildcard_command = null,
        .mode_list = .init(allocator),
    };
    return hotkey;
}

fn deinit_wildcard_command(self: *Hotkey) void {
    if (self.wildcard_command) |wildcard_command| {
        switch (wildcard_command) {
            .command => self.allocator.free(wildcard_command.command),
            else => {},
        }
        self.wildcard_command = null;
    }
}

pub fn set_wildcard_command(self: *Hotkey, wildcard_command: []const u8) !void {
    self.deinit_wildcard_command();
    const cmd = try self.allocator.dupe(u8, wildcard_command);
    self.wildcard_command = processCommand{ .command = cmd };
}

pub fn set_wildcard_forwarded(self: *Hotkey, forwarded: KeyPress) void {
    self.deinit_wildcard_command();
    self.wildcard_command = processCommand{ .forwarded = forwarded };
}

pub fn set_wildcard_unbound(self: *Hotkey) void {
    self.deinit_wildcard_command();
    self.wildcard_command = processCommand{ .unbound = void{} };
}

pub fn format(self: *const Hotkey, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    // if (fmt.len != 0) {
    //     std.fmt.invalidFmtError(fmt, self);
    // }
    _ = fmt;
    try writer.print("Hotkey{{", .{});
    try writer.print("\n  mode_list: {{", .{});
    {
        var it = self.mode_list.iterator();
        while (it.next()) |kv| {
            try writer.print("{s},", .{kv.key_ptr.*.name});
        }
    }
    try writer.print("}}", .{});
    try writer.print("\n  flags: {}", .{self.flags});
    try writer.print("\n  key: {}", .{self.key});
    try writer.print("\n  process_names: {{", .{});
    {
        for (self.process_names.items) |name| {
            try writer.print("\n    {s}", .{name});
        }
    }
    try writer.print("\n  }}", .{});
    try writer.print("\n  commands: {{", .{});
    {
        for (self.commands.items) |cmd| {
            switch (cmd) {
                .command => try writer.print("\n    cmd: {s},", .{cmd.command}),
                .forwarded => {
                    try writer.print("\n    forwarded:", .{});
                    try utils.indentPrint(self.allocator, writer, "    ", "{}", cmd.forwarded);
                },
                .unbound => try writer.print("\n    unbound", .{}),
            }
        }
    }
    try writer.print("\n  }}", .{});
    if (self.wildcard_command) |wildcard_command| {
        try writer.print("\n  wildcard_command: ", .{});
        switch (wildcard_command) {
            .command => try writer.print("{s}", .{wildcard_command.command}),
            .forwarded => {
                try writer.print("forwarded", .{});
                try utils.indentPrint(self.allocator, writer, "  ", "{}", wildcard_command.forwarded);
            },
            .unbound => try writer.print("unbound", .{}),
        }
    } else {
        try writer.print("\n  wildcard_command: null", .{});
    }
    try writer.print("\n}}", .{});
}

pub fn add_process_name(self: *Hotkey, process_name: []const u8) !void {
    const owned = try self.allocator.dupe(u8, process_name);
    // TODO: assuming ascii, need to handle utf8
    for (owned, 0..) |c, i| owned[i] = std.ascii.toLower(c);
    try self.process_names.append(self.allocator, owned);
}

pub fn add_proc_command(self: *Hotkey, command: []const u8) !void {
    const owned = try self.allocator.dupe(u8, command);
    try self.commands.append(self.allocator, processCommand{ .command = owned });
}

pub fn add_proc_unbound(self: *Hotkey) !void {
    try self.commands.append(self.allocator, processCommand{ .unbound = void{} });
}

pub fn add_proc_forward(self: *Hotkey, forwarded: KeyPress) !void {
    try self.commands.append(self.allocator, processCommand{ .forwarded = forwarded });
}

pub fn add_mode(self: *Hotkey, mode: *Mode) !void {
    if (self.mode_list.contains(mode)) {
        return error.@"Mode already exists in hotkey mode";
    }
    try self.mode_list.put(mode, {});
}

test "format hotkey" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc);
    defer hotkey.destroy();

    hotkey.flags = ModifierFlag{ .alt = true };
    hotkey.key = 0x2;
    try hotkey.add_process_name("some process_name");
    try hotkey.add_proc_command("some command");
    var mode = try Mode.init(alloc, "default");
    defer mode.deinit();
    // std.debug.print("{}\n", .{mode});
    try hotkey.add_mode(&mode);
    // try hotkey.set_wildcard_command("some wildcard_command");
    hotkey.set_wildcard_forwarded(KeyPress{ .flags = ModifierFlag{ .alt = true }, .key = 0x2 });

    const string = try std.fmt.allocPrint(alloc, "{s}", .{hotkey});
    defer alloc.free(string);

    std.debug.print("{s}\n", .{string});
}

test "hotkey map" {
    const alloc = std.testing.allocator;
    var m = HotkeyMap.empty;
    defer m.deinit(alloc);

    var key1 = try Hotkey.create(alloc);
    defer key1.destroy();
    key1.flags = ModifierFlag{ .alt = true };
    key1.key = 0x2;
    try key1.add_process_name("notepad.exe");
    std.debug.print("{}\n", .{key1});

    var key2 = try Hotkey.create(alloc);
    key2.flags = ModifierFlag{ .alt = true };
    key2.key = 0x2;
    defer key2.destroy();
    std.debug.print("{}\n", .{key2});

    var key1d = try Hotkey.create(alloc);
    defer key1d.destroy();
    key1d.flags = ModifierFlag{ .cmd = true };
    key1d.key = 0x2;
    try key1d.add_process_name("notepad.exe");
    std.debug.print("{}\n", .{key1d});

    try m.put(alloc, key1, {});
    try m.put(alloc, key2, {});
    try m.put(alloc, key1d, {});
    try std.testing.expectEqual(2, m.count());
}
