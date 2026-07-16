const std = @import("std");
const testing = std.testing;
const Hotkey = @This();
const Mode = @import("Mode.zig");
const utils = @import("utils.zig");
const ModifierFlag = @import("Keycodes.zig").ModifierFlag;
const log = std.log.scoped(.hotkey_array_hashmap);

// Error sets for better type safety
pub const ProcessCommandError = error{
    ProcessCommandAlreadyExists,
    WildcardCommandAlreadyExists,
    OutOfMemory,
};

pub const KeyPress = struct {
    flags: ModifierFlag,
    key: u32,
};

allocator: std.mem.Allocator,
/// The chords that must be pressed in order to fire this hotkey.
/// Owned. Invariant: len >= 1. chords[0] is the trigger.
chords: []const KeyPress,
/// `->`: run the action but still deliver the keypress. A property of the
/// binding, not of any one chord: each chord carries its own modifiers, so
/// storing passthrough in a chord's modifier set would leave it undefined
/// for every chord but the first. Applies to the final chord only.
passthrough: bool = false,
wildcard_command: ?ProcessCommand = null,
// Use ArrayHashMap for process name -> command mapping
mappings: std.StringArrayHashMapUnmanaged(ProcessCommand) = .empty,
mode_list: std.AutoArrayHashMapUnmanaged(*Mode, void) = .empty,

pub fn destroy(self: *Hotkey) void {
    var it = self.mappings.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        entry.value_ptr.*.deinit(self.allocator);
    }
    self.mappings.deinit(self.allocator);

    // Free wildcard command if any
    if (self.wildcard_command) |cmd| {
        cmd.deinit(self.allocator);
    }

    self.mode_list.deinit(self.allocator);
    self.allocator.free(self.chords);
    self.allocator.destroy(self);
}

pub fn create(allocator: std.mem.Allocator, chords: []const KeyPress) !*Hotkey {
    std.debug.assert(chords.len >= 1);
    const hotkey = try allocator.create(Hotkey);
    errdefer allocator.destroy(hotkey);
    hotkey.* = .{
        .allocator = allocator,
        .chords = try allocator.dupe(KeyPress, chords),
    };
    return hotkey;
}

pub fn isSequence(self: *const Hotkey) bool {
    return self.chords.len > 1;
}

pub const HotkeyMap = std.ArrayHashMapUnmanaged(*Hotkey, void, struct {
    pub fn hash(self: @This(), key: *Hotkey) u32 {
        _ = self;
        // Hash by the first chord's key code only, so hotkeys sharing a
        // trigger land in one probe chain and eql separates them.
        return key.chords[0].key;
    }
    pub fn eql(self: @This(), a: *Hotkey, b: *Hotkey, _: anytype) bool {
        _ = self;
        return Hotkey.eql(a, b);
    }
}, false);

pub fn eql(a: *Hotkey, b: *Hotkey) bool {
    if (a.chords.len != b.chords.len) return false;
    for (a.chords, b.chords) |x, y| {
        if (x.key != y.key) return false;
        if (!(compareLRMod(x.flags, y.flags, .alt) and
            compareLRMod(x.flags, y.flags, .cmd) and
            compareLRMod(x.flags, y.flags, .control) and
            compareLRMod(x.flags, y.flags, .shift) and
            x.flags.@"fn" == y.flags.@"fn" and
            x.flags.nx == y.flags.nx)) return false;
    }
    return true;
}

/// True when some one physical key press could match both chords.
///
/// This resolves per modifier family, not whole-set: the direction the
/// overlap needs can differ between families. `cmd + lshift - x` and
/// `lcmd + shift - x` overlap on a physical lcmd+lshift+x press, yet
/// neither whole-set `hotkeyFlagsMatch` direction holds — cmd needs
/// x-as-config, shift needs y-as-config.
fn chordsOverlap(x: KeyPress, y: KeyPress) bool {
    if (x.key != y.key) return false;
    return familyOverlap(x.flags, y.flags, .alt) and
        familyOverlap(x.flags, y.flags, .cmd) and
        familyOverlap(x.flags, y.flags, .control) and
        familyOverlap(x.flags, y.flags, .shift) and
        x.flags.@"fn" == y.flags.@"fn" and
        x.flags.nx == y.flags.nx;
}

/// Could one physical press satisfy this modifier family's requirement in
/// both configs? Derived from the per-family semantics `hotkeyFlagsMatch`
/// encodes, as the intersection of the keyboard states each config accepts:
///
///   - general bit set  -> accepts any event with general, left, or right
///                         (side bits in the config are ignored)
///   - general clear    -> accepts exactly the event whose left/right bits
///                         equal the config's, with general clear
///
/// So, writing ANY for a general config, L/R/LR for the side-bit configs
/// and NONE for an absent family:
///
///   ANY  vs ANY   -> true   (an event with the general bit matches both)
///   ANY  vs L/R/LR-> true   (that exact side state satisfies ANY too)
///   ANY  vs NONE  -> false  (NONE accepts only "family absent"; ANY needs it)
///   L    vs L     -> true   (same single accepted state)
///   L    vs R     -> false  (disjoint single states)
///   L    vs LR    -> false  (LR needs rcmd too; L needs it clear)
///   L/R/LR vs NONE-> false  (NONE needs the family absent)
///   NONE vs NONE  -> true   (both accept "family absent")
fn familyOverlap(a: ModifierFlag, b: ModifierFlag, comptime mod: enum { alt, cmd, control, shift }) bool {
    const general_field, const left_field, const right_field = switch (mod) {
        .alt => .{ "alt", "lalt", "ralt" },
        .cmd => .{ "cmd", "lcmd", "rcmd" },
        .control => .{ "control", "lcontrol", "rcontrol" },
        .shift => .{ "shift", "lshift", "rshift" },
    };

    const a_general = @field(a, general_field);
    const b_general = @field(b, general_field);
    const a_left = @field(a, left_field);
    const a_right = @field(a, right_field);
    const b_left = @field(b, left_field);
    const b_right = @field(b, right_field);

    if (a_general and b_general) return true;
    // One side is general: it accepts any event carrying this family, so the
    // other's accepted state qualifies iff it names a side at all.
    if (a_general) return b_left or b_right;
    if (b_general) return a_left or a_right;
    // Neither is general: each accepts exactly one keyboard state.
    return a_left == b_left and a_right == b_right;
}

/// True when one hotkey's chord list is a prefix of the other's (equal
/// length counts), comparing chords with overlap semantics — chords that
/// some one physical press could match both of.
///
/// Combined with processScopesOverlap this is the whole conflict rule, and
/// because chordsOverlap resolves per modifier family it is exact: any two
/// configs a single press could both match are rejected. That is what makes
/// "at most one hotkey matches any (mode, prefix, process)" true, and hence
/// probe order in PrefixLookupContext unobservable.
pub fn onePrefixesOther(a: *const Hotkey, b: *const Hotkey) bool {
    const n = @min(a.chords.len, b.chords.len);
    for (a.chords[0..n], b.chords[0..n]) |x, y| {
        if (!chordsOverlap(x, y)) return false;
    }
    return true;
}

fn compareLRMod(a: ModifierFlag, b: ModifierFlag, comptime mod: enum { alt, cmd, control, shift }) bool {
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

    const a_general = @field(a, general_field);
    const a_left = @field(a, left_field);
    const a_right = @field(a, right_field);

    const b_general = @field(b, general_field);
    const b_left = @field(b, left_field);
    const b_right = @field(b, right_field);

    // For HashMap equality, we need exact match
    // Both hotkeys are from config, so exact comparison is correct
    return a_general == b_general and a_left == b_left and a_right == b_right;
}

/// Looks a chord prefix up against a mode's hotkeys.
///
/// The caller reads the result's chord count to decide what happened:
///   chords.len == prefix.len -> complete, fire it
///   chords.len >  prefix.len -> pending, consume and arm the timer
///   null                     -> nothing applicable
///
/// Enumerating candidates is unnecessary: when two sequences share a
/// prefix, either one proves "pending" and the next chord disambiguates.
pub const PrefixLookupContext = struct {
    /// Frontmost process, or null to match structurally — ignoring
    /// whether the hotkey has an action that applies here. The null form
    /// answers "did any rule claim this chord?", which gates the
    /// capture-mode fallback.
    process_name: ?[]const u8,

    pub fn hash(_: @This(), prefix: []const KeyPress) u32 {
        std.debug.assert(prefix.len >= 1);
        return prefix[0].key;
    }

    pub fn eql(self: @This(), prefix: []const KeyPress, config: *Hotkey, _: usize) bool {
        if (config.chords.len < prefix.len) return false;
        for (prefix, config.chords[0..prefix.len]) |ev, cfg| {
            if (cfg.key != ev.key) return false;
            if (!hotkeyFlagsMatch(cfg.flags, ev.flags)) return false;
        }
        // Skipping inapplicable hotkeys during probing is what lets a
        // `cmd - q ["Terminal"]` entry not shadow a
        // `cmd - q, cmd - q ["XYZ"]` entry while XYZ is frontmost.
        const proc = self.process_name orelse return true;
        return config.find_command_for_process(proc) != null;
    }
};

/// Wildcard-modifier lookup context for capture-mode layer rules.
/// Matches a config hotkey by key code alone, ignoring the keyboard
/// event's modifier flags — but ONLY if the config rule itself has
/// no declared modifiers (so explicit-modifier rules still need an
/// exact match elsewhere). The caller is expected to OR the user's
/// modifiers into the forward target after a wildcard match.
pub const WildcardLookupContext = struct {
    process_name: []const u8,

    pub fn hash(_: @This(), key: Hotkey.KeyPress) u32 {
        return key.key;
    }

    pub fn eql(self: @This(), keyboard: Hotkey.KeyPress, config: *Hotkey, _: usize) bool {
        // len == 1: the fallback must never fire a sequence off one chord.
        if (config.chords.len != 1) return false;
        if (config.chords[0].key != keyboard.key) return false;
        if (!config.chords[0].flags.isEmpty()) return false;
        return config.find_command_for_process(self.process_name) != null;
    }
};

/// Compare hotkey flags, handling left/right modifier logic
/// config = hotkey from config file, keyboard = event from keyboard
pub fn hotkeyFlagsMatch(config: ModifierFlag, keyboard: ModifierFlag) bool {
    // Match logic from original skhd:
    // If config has general modifier (alt), keyboard can have general, left, or right
    // If config has specific modifier (lalt), keyboard must match exactly

    const alt_match = if (config.alt)
        (keyboard.alt or keyboard.lalt or keyboard.ralt)
    else
        (config.lalt == keyboard.lalt and config.ralt == keyboard.ralt and config.alt == keyboard.alt);

    const cmd_match = if (config.cmd)
        (keyboard.cmd or keyboard.lcmd or keyboard.rcmd)
    else
        (config.lcmd == keyboard.lcmd and config.rcmd == keyboard.rcmd and config.cmd == keyboard.cmd);

    const ctrl_match = if (config.control)
        (keyboard.control or keyboard.lcontrol or keyboard.rcontrol)
    else
        (config.lcontrol == keyboard.lcontrol and config.rcontrol == keyboard.rcontrol and config.control == keyboard.control);

    const shift_match = if (config.shift)
        (keyboard.shift or keyboard.lshift or keyboard.rshift)
    else
        (config.lshift == keyboard.lshift and config.rshift == keyboard.rshift and config.shift == keyboard.shift);

    return alt_match and cmd_match and ctrl_match and shift_match and
        config.@"fn" == keyboard.@"fn" and
        config.nx == keyboard.nx;
}

pub const ProcessCommand = union(enum) {
    command: [:0]const u8,
    forwarded: KeyPress,
    unbound: void,
    activation: Activation,

    pub const Activation = struct {
        mode_name: []const u8,
        command: ?[:0]const u8 = null,

        fn eql(self: Activation, other: Activation) bool {
            if (!std.mem.eql(u8, self.mode_name, other.mode_name)) return false;
            if (self.command == null and other.command == null) return true;
            if (self.command != null and other.command != null) {
                return std.mem.eql(u8, self.command.?, other.command.?);
            }
            return false;
        }
    };

    /// Create a command variant with a duplicated null-terminated string
    pub fn initCommand(allocator: std.mem.Allocator, cmd: []const u8) !ProcessCommand {
        return ProcessCommand{ .command = try allocator.dupeZ(u8, cmd) };
    }

    /// Create a forwarded variant
    pub fn initForwarded(key_press: KeyPress) ProcessCommand {
        return ProcessCommand{ .forwarded = key_press };
    }

    /// Create an unbound variant
    pub fn initUnbound() ProcessCommand {
        return ProcessCommand{ .unbound = {} };
    }

    /// Create an activation variant with a duplicated string and optional command
    pub fn initActivation(allocator: std.mem.Allocator, mode_name: []const u8, cmd: ?[]const u8) !ProcessCommand {
        return ProcessCommand{ .activation = .{
            .mode_name = try allocator.dupe(u8, mode_name),
            .command = if (cmd) |c| try allocator.dupeZ(u8, c) else null,
        } };
    }

    /// Free any owned memory
    pub fn deinit(self: ProcessCommand, allocator: std.mem.Allocator) void {
        switch (self) {
            .command => |str| allocator.free(str),
            .activation => |act| {
                allocator.free(act.mode_name);
                if (act.command) |cmd| allocator.free(cmd);
            },
            else => {},
        }
    }
};

pub fn format(self: Hotkey, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("Hotkey{");
    try writer.writeAll("\n  mode_list: {");
    {
        var it = self.mode_list.iterator();
        while (it.next()) |kv| {
            try writer.print("{s},", .{kv.key_ptr.*.name});
        }
    }
    try writer.writeAll("}");
    try writer.writeAll("\n  chords: [");
    for (self.chords, 0..) |chord, i| {
        if (i != 0) try writer.writeAll(", ");
        try writer.print("{f}-{}", .{ chord.flags, chord.key });
    }
    try writer.writeAll("]");
    try writer.print("\n  process_mappings: {} entries", .{self.mappings.count()});
    try writer.writeAll("\n}");
}

pub fn add_process_command(self: *Hotkey, process_name: []const u8, command: []const u8) ProcessCommandError!void {
    const owned_cmd = try ProcessCommand.initCommand(self.allocator, command);
    errdefer owned_cmd.deinit(self.allocator);

    if (std.mem.eql(u8, process_name, "*")) {
        if (self.wildcard_command) |_| {
            return error.WildcardCommandAlreadyExists;
        }

        self.wildcard_command = owned_cmd;
        return;
    }

    const owned_name = try self.toLowercaseOwned(process_name);
    errdefer self.allocator.free(owned_name);

    // Check if we're replacing an existing mapping
    if (self.mappings.get(owned_name)) |existing_cmd| {
        if (std.meta.activeTag(existing_cmd) == ProcessCommand.command and std.mem.eql(u8, existing_cmd.command, owned_cmd.command)) {
            self.allocator.free(owned_name);
            owned_cmd.deinit(self.allocator);
            return;
        }
        return error.ProcessCommandAlreadyExists;
    }

    // Put into hashmap
    try self.mappings.put(self.allocator, owned_name, owned_cmd);
}

fn toLowercaseOwned(self: *Hotkey, process_name: []const u8) ![]const u8 {
    const owned_name = try self.allocator.dupe(u8, process_name);
    for (owned_name, 0..) |c, i| {
        owned_name[i] = std.ascii.toLower(c);
    }
    return owned_name;
}

pub fn add_process_forward(self: *Hotkey, process_name: []const u8, key_press: KeyPress) ProcessCommandError!void {
    const owned_cmd = ProcessCommand.initForwarded(key_press);

    if (std.mem.eql(u8, process_name, "*")) {
        if (self.wildcard_command) |_| {
            return error.WildcardCommandAlreadyExists;
        }

        self.wildcard_command = owned_cmd;
        return;
    }

    const owned_name = try self.toLowercaseOwned(process_name);
    errdefer self.allocator.free(owned_name);

    // Check if we're replacing an existing mapping
    if (self.mappings.get(owned_name)) |existing_cmd| {
        if (std.meta.activeTag(existing_cmd) == ProcessCommand.forwarded and
            std.meta.eql(existing_cmd.forwarded, owned_cmd.forwarded))
        {
            self.allocator.free(owned_name);
            return; // No need to replace if it's the same
        }
        return error.ProcessCommandAlreadyExists;
    }

    // Put into hashmap
    try self.mappings.put(self.allocator, owned_name, owned_cmd);
}

pub fn add_process_unbound(self: *Hotkey, process_name: []const u8) ProcessCommandError!void {
    const owned_cmd = ProcessCommand.initUnbound();

    if (std.mem.eql(u8, process_name, "*")) {
        if (self.wildcard_command) |_| {
            return error.WildcardCommandAlreadyExists;
        }

        self.wildcard_command = owned_cmd;
        return;
    }

    const owned_name = try self.toLowercaseOwned(process_name);
    errdefer self.allocator.free(owned_name);

    // Check if we're replacing an existing mapping
    if (self.mappings.get(owned_name)) |existing_cmd| {
        if (std.meta.activeTag(existing_cmd) == ProcessCommand.unbound) {
            self.allocator.free(owned_name);
            return; // No need to replace if it's already unbound
        }
        return error.ProcessCommandAlreadyExists;
    }

    // Put into hashmap
    try self.mappings.put(self.allocator, owned_name, owned_cmd);
}

pub fn add_process_activation(self: *Hotkey, process_name: []const u8, mode_name: []const u8, cmd: ?[]const u8) ProcessCommandError!void {
    const owned_cmd = try ProcessCommand.initActivation(self.allocator, mode_name, cmd);
    errdefer owned_cmd.deinit(self.allocator);

    if (std.mem.eql(u8, process_name, "*")) {
        if (self.wildcard_command) |_| {
            return error.WildcardCommandAlreadyExists;
        }

        self.wildcard_command = owned_cmd;
        return;
    }

    const owned_name = try self.toLowercaseOwned(process_name);
    errdefer self.allocator.free(owned_name);

    // Check if we're replacing an existing mapping
    if (self.mappings.get(owned_name)) |existing_cmd| {
        if (std.meta.activeTag(existing_cmd) == ProcessCommand.activation and existing_cmd.activation.eql(owned_cmd.activation)) {
            self.allocator.free(owned_name);
            owned_cmd.deinit(self.allocator);
            return; // No need to replace if it's the same
        }
        return error.ProcessCommandAlreadyExists;
    }

    // Put into hashmap
    try self.mappings.put(self.allocator, owned_name, owned_cmd);
}

pub fn find_command_for_process(self: *const Hotkey, process_name: []const u8) ?ProcessCommand {
    if (process_name.len == 0 or std.mem.eql(u8, process_name, "*")) {
        return self.wildcard_command;
    }

    // Create lowercase version for lookup
    var name_buf: [256]u8 = undefined;
    if (process_name.len > name_buf.len) return self.wildcard_command;

    for (process_name, 0..) |c, i| {
        name_buf[i] = std.ascii.toLower(c);
    }
    const lower_name = name_buf[0..process_name.len];

    // First try to find exact match
    if (self.mappings.get(lower_name)) |cmd| {
        return cmd;
    }

    // If no exact match, return wildcard
    return self.wildcard_command;
}

pub fn hasWildcardAction(self: *const Hotkey) bool {
    return self.wildcard_command != null;
}

pub fn hasExplicitProcess(self: *const Hotkey, process_name: []const u8) bool {
    var it = self.mappings.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, process_name)) return true;
    }
    return false;
}

pub fn processScopesOverlap(a: *const Hotkey, b: *const Hotkey) bool {
    if (a.hasWildcardAction() or b.hasWildcardAction()) return true;
    var it = a.mappings.iterator();
    while (it.next()) |entry| {
        if (b.hasExplicitProcess(entry.key_ptr.*)) return true;
    }
    return false;
}

pub fn add_mode(self: *Hotkey, mode: *Mode) !void {
    if (self.mode_list.contains(mode)) {
        return error.ModeAlreadyExistsInHotkey;
    }
    try self.mode_list.put(self.allocator, mode, {});
}

// Additional utility methods
pub fn getProcessCount(self: *const Hotkey) usize {
    return self.mappings.count();
}

test "ArrayHashMap hotkey implementation" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc, &.{.{ .flags = ModifierFlag{ .alt = true }, .key = 0x2 }});
    defer hotkey.destroy();

    // Test the API
    try hotkey.add_process_command("firefox", "echo firefox");
    try hotkey.add_process_command("chrome", "echo chrome");
    try hotkey.add_process_forward("terminal", KeyPress{ .flags = .{}, .key = 0x24 });

    // Test lookup
    const firefox_cmd = hotkey.find_command_for_process("Firefox");
    try std.testing.expect(firefox_cmd != null);
    try std.testing.expectEqualStrings("echo firefox", firefox_cmd.?.command);

    // Test case insensitive
    const chrome_cmd = hotkey.find_command_for_process("CHROME");
    try std.testing.expect(chrome_cmd != null);
    try std.testing.expectEqualStrings("echo chrome", chrome_cmd.?.command);

    // Test wildcard
    try hotkey.add_process_command("*", "echo default");
    const unknown_cmd = hotkey.find_command_for_process("unknown");
    try std.testing.expect(unknown_cmd != null);
    try std.testing.expectEqualStrings("echo default", unknown_cmd.?.command);

    // Test count
    try std.testing.expectEqual(@as(usize, 3), hotkey.getProcessCount()); // firefox, chrome, terminal (wildcard is separate)
}

test "hotkey initialization" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc, &.{.{ .flags = .{}, .key = 0 }});
    defer hotkey.destroy();

    // Test that chords holds exactly the single chord passed in
    try std.testing.expectEqual(@as(usize, 1), hotkey.chords.len);
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(hotkey.chords[0].flags)));
    try std.testing.expectEqual(@as(u32, 0), hotkey.chords[0].key);

    // Test that other fields are properly initialized
    try std.testing.expectEqual(@as(?ProcessCommand, null), hotkey.wildcard_command);
    try std.testing.expectEqual(@as(usize, 0), hotkey.mappings.count());
    try std.testing.expectEqual(@as(usize, 0), hotkey.mode_list.count());
}

test "add_process returns error on duplicate" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc, &.{.{ .flags = .{}, .key = 0 }});
    defer hotkey.destroy();

    // First mapping should succeed
    try hotkey.add_process_command("firefox", "echo firefox");

    // Duplicate mapping should fail
    const result = hotkey.add_process_command("firefox", "echo firefox2");
    try std.testing.expectError(error.ProcessCommandAlreadyExists, result);

    // Case insensitive duplicate should also fail
    const result2 = hotkey.add_process_command("FIREFOX", "echo firefox3");
    try std.testing.expectError(error.ProcessCommandAlreadyExists, result2);

    // Original command should still be there
    const cmd = hotkey.find_command_for_process("firefox");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("echo firefox", cmd.?.command);

    // Test wildcard duplicate
    try hotkey.add_process_command("*", "echo wildcard");
    const wildcard_result = hotkey.add_process_command("*", "echo wildcard2");
    try std.testing.expectError(error.WildcardCommandAlreadyExists, wildcard_result);

    // Original wildcard should still be there
    const wildcard_cmd = hotkey.find_command_for_process("unknown_process");
    try std.testing.expect(wildcard_cmd != null);
    try std.testing.expectEqualStrings("echo wildcard", wildcard_cmd.?.command);
}

test "process scopes overlap for shared explicit app or wildcard" {
    const alloc = std.testing.allocator;
    var terminal = try Hotkey.create(alloc, &.{.{ .flags = .{}, .key = 0 }});
    defer terminal.destroy();
    try terminal.add_process_command("Terminal", "echo terminal");

    var protected = try Hotkey.create(alloc, &.{.{ .flags = .{}, .key = 0 }});
    defer protected.destroy();
    try protected.add_process_command("Protected App", "echo protected");

    var same_protected = try Hotkey.create(alloc, &.{.{ .flags = .{}, .key = 0 }});
    defer same_protected.destroy();
    try same_protected.add_process_command("protected app", "echo same");

    var wildcard = try Hotkey.create(alloc, &.{.{ .flags = .{}, .key = 0 }});
    defer wildcard.destroy();
    try wildcard.add_process_command("*", "echo wildcard");

    try testing.expect(!processScopesOverlap(terminal, protected));
    try testing.expect(processScopesOverlap(protected, same_protected));
    try testing.expect(processScopesOverlap(wildcard, protected));
}

test "ArrayHashMap performance characteristics" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc, &.{.{ .flags = .{}, .key = 0 }});
    defer hotkey.destroy();

    // Add many mappings
    for (0..100) |i| {
        const name = try std.fmt.allocPrint(alloc, "process_{}", .{i});
        defer alloc.free(name);
        const cmd = try std.fmt.allocPrint(alloc, "echo process_{}", .{i});
        defer alloc.free(cmd);

        try hotkey.add_process_command(name, cmd);
    }

    // Test some lookups
    const cmd_50 = hotkey.find_command_for_process("Process_50");
    try std.testing.expect(cmd_50 != null);
    try std.testing.expectEqualStrings("echo process_50", cmd_50.?.command);

    const cmd_99 = hotkey.find_command_for_process("PROCESS_99");
    try std.testing.expect(cmd_99 != null);
    try std.testing.expectEqualStrings("echo process_99", cmd_99.?.command);

    try std.testing.expectEqual(@as(usize, 100), hotkey.getProcessCount());
}

test "hotkeyFlagsMatch behavior" {
    // Test general modifier matching: config has general (alt), keyboard can have general, left, or right
    {
        const config = ModifierFlag{ .alt = true };
        const kb_general = ModifierFlag{ .alt = true };
        const kb_left = ModifierFlag{ .lalt = true };
        const kb_right = ModifierFlag{ .ralt = true };

        try testing.expect(hotkeyFlagsMatch(config, kb_general));
        try testing.expect(hotkeyFlagsMatch(config, kb_left));
        try testing.expect(hotkeyFlagsMatch(config, kb_right));
    }

    // Test specific modifier matching: config has specific (lalt), keyboard must match exactly
    {
        const config = ModifierFlag{ .lalt = true };
        const kb_general = ModifierFlag{ .alt = true };
        const kb_left = ModifierFlag{ .lalt = true };
        const kb_right = ModifierFlag{ .ralt = true };

        try testing.expect(!hotkeyFlagsMatch(config, kb_general));
        try testing.expect(hotkeyFlagsMatch(config, kb_left));
        try testing.expect(!hotkeyFlagsMatch(config, kb_right));
    }

    // Test multiple modifiers
    {
        const config = ModifierFlag{ .cmd = true, .shift = true };
        const kb_match = ModifierFlag{ .lcmd = true, .shift = true };
        const kb_no_match = ModifierFlag{ .lcmd = true }; // Missing shift

        try testing.expect(hotkeyFlagsMatch(config, kb_match));
        try testing.expect(!hotkeyFlagsMatch(config, kb_no_match));
    }
}

test "duplicate commands allowed if identical" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc, &.{.{ .flags = .{}, .key = 0 }});
    defer hotkey.destroy();

    // Test duplicate command with same content is allowed
    try hotkey.add_process_command("firefox", "echo firefox");
    // Adding the exact same command should succeed silently
    try hotkey.add_process_command("firefox", "echo firefox");

    // Verify only one entry exists
    try std.testing.expectEqual(@as(usize, 1), hotkey.getProcessCount());
    const cmd = hotkey.find_command_for_process("firefox");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("echo firefox", cmd.?.command);

    // Test with case-insensitive duplicate
    try hotkey.add_process_command("FIREFOX", "echo firefox");
    try std.testing.expectEqual(@as(usize, 1), hotkey.getProcessCount());

    // But different command should fail
    const result = hotkey.add_process_command("firefox", "echo different");
    try std.testing.expectError(error.ProcessCommandAlreadyExists, result);
}

test "duplicate forwards allowed if identical" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc, &.{.{ .flags = .{}, .key = 0 }});
    defer hotkey.destroy();

    const key_press = KeyPress{ .flags = .{ .cmd = true }, .key = 0x24 };

    // First forward should succeed
    try hotkey.add_process_forward("terminal", key_press);
    // Adding the exact same forward should succeed silently
    try hotkey.add_process_forward("terminal", key_press);

    // Verify only one entry exists
    try std.testing.expectEqual(@as(usize, 1), hotkey.getProcessCount());
    const cmd = hotkey.find_command_for_process("terminal");
    try std.testing.expect(cmd != null);
    try std.testing.expect(cmd.? == .forwarded);
    try std.testing.expect(std.meta.eql(cmd.?.forwarded, key_press));

    // Different forward should fail
    const different_key = KeyPress{ .flags = .{ .alt = true }, .key = 0x25 };
    const result = hotkey.add_process_forward("terminal", different_key);
    try std.testing.expectError(error.ProcessCommandAlreadyExists, result);
}

test "duplicate unbound allowed if identical" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc, &.{.{ .flags = .{}, .key = 0 }});
    defer hotkey.destroy();

    // First unbound should succeed
    try hotkey.add_process_unbound("notepad");
    // Adding the same unbound should succeed silently
    try hotkey.add_process_unbound("notepad");

    // Verify only one entry exists
    try std.testing.expectEqual(@as(usize, 1), hotkey.getProcessCount());
    const cmd = hotkey.find_command_for_process("notepad");
    try std.testing.expect(cmd != null);
    try std.testing.expect(cmd.? == .unbound);

    // Case insensitive duplicate should also work
    try hotkey.add_process_unbound("NOTEPAD");
    try std.testing.expectEqual(@as(usize, 1), hotkey.getProcessCount());

    // But changing from unbound to command should fail
    const result = hotkey.add_process_command("notepad", "echo notepad");
    try std.testing.expectError(error.ProcessCommandAlreadyExists, result);
}

test "duplicate activation allowed if identical" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc, &.{.{ .flags = .{}, .key = 0 }});
    defer hotkey.destroy();

    // Test activation without command
    try hotkey.add_process_activation("vscode", "insert", null);
    try hotkey.add_process_activation("vscode", "insert", null);

    try std.testing.expectEqual(@as(usize, 1), hotkey.getProcessCount());
    const cmd = hotkey.find_command_for_process("vscode");
    try std.testing.expect(cmd != null);
    try std.testing.expect(cmd.? == .activation);
    try std.testing.expectEqualStrings("insert", cmd.?.activation.mode_name);
    try std.testing.expect(cmd.?.activation.command == null);

    // Test activation with command
    try hotkey.add_process_activation("sublime", "visual", "echo visual mode");
    try hotkey.add_process_activation("sublime", "visual", "echo visual mode");

    try std.testing.expectEqual(@as(usize, 2), hotkey.getProcessCount());
    const cmd2 = hotkey.find_command_for_process("sublime");
    try std.testing.expect(cmd2 != null);
    try std.testing.expect(cmd2.? == .activation);
    try std.testing.expectEqualStrings("visual", cmd2.?.activation.mode_name);
    try std.testing.expectEqualStrings("echo visual mode", cmd2.?.activation.command.?);

    // Different mode name should fail
    const result = hotkey.add_process_activation("vscode", "normal", null);
    try std.testing.expectError(error.ProcessCommandAlreadyExists, result);

    // Different command should fail
    const result2 = hotkey.add_process_activation("sublime", "visual", "echo different");
    try std.testing.expectError(error.ProcessCommandAlreadyExists, result2);
}

test "wildcard duplicate handling" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc, &.{.{ .flags = .{}, .key = 0 }});
    defer hotkey.destroy();

    // Test wildcard command duplicate
    try hotkey.add_process_command("*", "echo wildcard");
    const result = hotkey.add_process_command("*", "echo wildcard");
    // Wildcard doesn't allow duplicates even if identical
    try std.testing.expectError(error.WildcardCommandAlreadyExists, result);

    // Test wildcard forward
    var hotkey2 = try Hotkey.create(alloc, &.{.{ .flags = .{}, .key = 0 }});
    defer hotkey2.destroy();

    const key_press = KeyPress{ .flags = .{}, .key = 0x24 };
    try hotkey2.add_process_forward("*", key_press);
    const result2 = hotkey2.add_process_forward("*", key_press);
    try std.testing.expectError(error.WildcardCommandAlreadyExists, result2);

    // Test wildcard unbound
    var hotkey3 = try Hotkey.create(alloc, &.{.{ .flags = .{}, .key = 0 }});
    defer hotkey3.destroy();

    try hotkey3.add_process_unbound("*");
    const result3 = hotkey3.add_process_unbound("*");
    try std.testing.expectError(error.WildcardCommandAlreadyExists, result3);

    // Test wildcard activation
    var hotkey4 = try Hotkey.create(alloc, &.{.{ .flags = .{}, .key = 0 }});
    defer hotkey4.destroy();

    try hotkey4.add_process_activation("*", "mode", "cmd");
    const result4 = hotkey4.add_process_activation("*", "mode", "cmd");
    try std.testing.expectError(error.WildcardCommandAlreadyExists, result4);
}

test "onePrefixesOther detects prefix relationships with overlap semantics" {
    const alloc = std.testing.allocator;
    const cmd_q = KeyPress{ .flags = .{ .cmd = true }, .key = 0x0C };
    const lcmd_q = KeyPress{ .flags = .{ .lcmd = true }, .key = 0x0C };
    const cmd_a = KeyPress{ .flags = .{ .cmd = true }, .key = 0x00 };

    var single = try Hotkey.create(alloc, &.{cmd_q});
    defer single.destroy();
    var double = try Hotkey.create(alloc, &.{ cmd_q, cmd_q });
    defer double.destroy();
    var other = try Hotkey.create(alloc, &.{cmd_a});
    defer other.destroy();
    var specific = try Hotkey.create(alloc, &.{lcmd_q});
    defer specific.destroy();

    try testing.expect(onePrefixesOther(single, double));
    try testing.expect(onePrefixesOther(double, single));
    try testing.expect(!onePrefixesOther(single, other));
    // Overlap, not equality: a physical lcmd-q press matches both.
    try testing.expect(onePrefixesOther(single, specific));
}

test "chord overlap resolves per modifier family, not whole-set" {
    const alloc = std.testing.allocator;
    const x_key: u32 = 0x07;
    const y_key: u32 = 0x10;

    // The direction the overlap needs differs per family: cmd needs
    // general-vs-specific one way, shift needs it the other way. A whole-set
    // hotkeyFlagsMatch in either direction misses this, yet one physical
    // lcmd+lshift+x press matches both configs.
    var cmd_lshift = try Hotkey.create(alloc, &.{.{ .flags = .{ .cmd = true, .lshift = true }, .key = x_key }});
    defer cmd_lshift.destroy();
    var lcmd_shift_seq = try Hotkey.create(alloc, &.{
        .{ .flags = .{ .lcmd = true, .shift = true }, .key = x_key },
        .{ .flags = .{ .cmd = true }, .key = y_key },
    });
    defer lcmd_shift_seq.destroy();

    try testing.expect(onePrefixesOther(cmd_lshift, lcmd_shift_seq));
    try testing.expect(onePrefixesOther(lcmd_shift_seq, cmd_lshift));
}

test "chord overlap does not over-tighten" {
    const alloc = std.testing.allocator;
    const x_key: u32 = 0x07;

    var lcmd_x = try Hotkey.create(alloc, &.{.{ .flags = .{ .lcmd = true }, .key = x_key }});
    defer lcmd_x.destroy();
    var rcmd_x = try Hotkey.create(alloc, &.{.{ .flags = .{ .rcmd = true }, .key = x_key }});
    defer rcmd_x.destroy();
    var cmd_x = try Hotkey.create(alloc, &.{.{ .flags = .{ .cmd = true }, .key = x_key }});
    defer cmd_x.destroy();
    var bare_x = try Hotkey.create(alloc, &.{.{ .flags = .{}, .key = x_key }});
    defer bare_x.destroy();
    var cmd_shift_x = try Hotkey.create(alloc, &.{.{ .flags = .{ .cmd = true, .shift = true }, .key = x_key }});
    defer cmd_shift_x.destroy();
    var cmd_x_2 = try Hotkey.create(alloc, &.{.{ .flags = .{ .cmd = true }, .key = x_key }});
    defer cmd_x_2.destroy();

    // No physical press carries lcmd and rcmd-without-lcmd at once.
    try testing.expect(!onePrefixesOther(lcmd_x, rcmd_x));
    // A general modifier still requires the family to be present.
    try testing.expect(!onePrefixesOther(cmd_x, bare_x));
    // An absent family requires the event to lack it entirely.
    try testing.expect(!onePrefixesOther(cmd_x, cmd_shift_x));

    // Genuine overlaps stay overlaps.
    try testing.expect(onePrefixesOther(cmd_x, lcmd_x));
    try testing.expect(onePrefixesOther(cmd_x, cmd_x_2));
}

test "prefix lookup resolves complete vs pending and skips inapplicable scopes" {
    const alloc = std.testing.allocator;
    const cmd_q = KeyPress{ .flags = .{ .cmd = true }, .key = 0x0C };

    var immediate = try Hotkey.create(alloc, &.{cmd_q});
    defer immediate.destroy();
    try immediate.add_process_command("Terminal", "echo t");

    var sequence = try Hotkey.create(alloc, &.{ cmd_q, cmd_q });
    defer sequence.destroy();
    try sequence.add_process_command("Protected App", "echo p");

    var map: HotkeyMap = .empty;
    defer map.deinit(alloc);
    try map.put(alloc, immediate, {});
    try map.put(alloc, sequence, {});

    const prefix: []const KeyPress = &.{cmd_q};

    // Terminal: the one-chord rule applies -> complete.
    try testing.expectEqual(immediate, map.getKeyAdapted(prefix, PrefixLookupContext{
        .process_name = "Terminal",
    }).?);

    // Protected App: the one-chord rule is skipped during probing, so the
    // sequence is reachable -> pending (chords.len > prefix.len).
    const in_protected = map.getKeyAdapted(prefix, PrefixLookupContext{
        .process_name = "Protected App",
    }).?;
    try testing.expectEqual(sequence, in_protected);
    try testing.expect(in_protected.chords.len > prefix.len);

    // Firefox: neither applies -> cmd-q passes through to macOS.
    try testing.expect(map.getKeyAdapted(prefix, PrefixLookupContext{
        .process_name = "Firefox",
    }) == null);

    // Process-blind: something claimed the chord, regardless of scope.
    try testing.expect(map.getKeyAdapted(prefix, PrefixLookupContext{
        .process_name = null,
    }) != null);
}

test "prefix lookup narrows a shared prefix on the second chord" {
    const alloc = std.testing.allocator;
    const cmd_k = KeyPress{ .flags = .{ .cmd = true }, .key = 0x28 };
    const cmd_c = KeyPress{ .flags = .{ .cmd = true }, .key = 0x08 };
    const cmd_u = KeyPress{ .flags = .{ .cmd = true }, .key = 0x20 };

    var comment = try Hotkey.create(alloc, &.{ cmd_k, cmd_c });
    defer comment.destroy();
    try comment.add_process_command("*", "comment");
    var uncomment = try Hotkey.create(alloc, &.{ cmd_k, cmd_u });
    defer uncomment.destroy();
    try uncomment.add_process_command("*", "uncomment");

    var map: HotkeyMap = .empty;
    defer map.deinit(alloc);
    try map.put(alloc, comment, {});
    try map.put(alloc, uncomment, {});

    // [cmd-k] matches both; either proves "pending". We don't care which.
    const step1: []const KeyPress = &.{cmd_k};
    const pending = map.getKeyAdapted(step1, PrefixLookupContext{ .process_name = "Code" }).?;
    try testing.expect(pending.chords.len > step1.len);

    // The second chord disambiguates.
    const step2: []const KeyPress = &.{ cmd_k, cmd_u };
    const done = map.getKeyAdapted(step2, PrefixLookupContext{ .process_name = "Code" }).?;
    try testing.expectEqual(uncomment, done);
    try testing.expectEqual(step2.len, done.chords.len);
}

test "wildcard context rejects sequences and inapplicable scopes" {
    const alloc = std.testing.allocator;
    const h = KeyPress{ .flags = .{}, .key = 0x04 };

    var transparent = try Hotkey.create(alloc, &.{h});
    defer transparent.destroy();
    try transparent.add_process_command("*", "left");

    var seq = try Hotkey.create(alloc, &.{ h, h });
    defer seq.destroy();
    try seq.add_process_command("*", "nope");

    var map: HotkeyMap = .empty;
    defer map.deinit(alloc);
    try map.put(alloc, seq, {});
    try map.put(alloc, transparent, {});

    // The fallback must never fire a sequence off a single chord.
    const found = map.getKeyAdapted(
        Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = 0x04 },
        WildcardLookupContext{ .process_name = "Firefox" },
    );
    try testing.expectEqual(transparent, found.?);
}

test "create dupes chords and reports sequence-ness" {
    const alloc = std.testing.allocator;
    const chords = [_]KeyPress{
        .{ .flags = .{ .cmd = true }, .key = 0x28 },
        .{ .flags = .{ .cmd = true }, .key = 0x08 },
    };
    var hotkey = try Hotkey.create(alloc, &chords);
    defer hotkey.destroy();

    try testing.expectEqual(@as(usize, 2), hotkey.chords.len);
    try testing.expect(hotkey.isSequence());
    try testing.expectEqual(@as(u32, 0x08), hotkey.chords[1].key);
    // Owned, not borrowed.
    try testing.expect(hotkey.chords.ptr != &chords);
}

test "single chord hotkey is not a sequence" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc, &.{.{ .flags = .{ .alt = true }, .key = 0x02 }});
    defer hotkey.destroy();
    try testing.expect(!hotkey.isSequence());
    try testing.expectEqual(@as(u32, 0x02), hotkey.chords[0].key);
}

test "eql compares whole chord lists" {
    const alloc = std.testing.allocator;
    const q = KeyPress{ .flags = .{ .cmd = true }, .key = 0x0C };

    var single = try Hotkey.create(alloc, &.{q});
    defer single.destroy();
    var double = try Hotkey.create(alloc, &.{ q, q });
    defer double.destroy();
    var double2 = try Hotkey.create(alloc, &.{ q, q });
    defer double2.destroy();

    // Different lengths are never equal — this is what lets `cmd - q`
    // and `cmd - q, cmd - q` coexist in one HotkeyMap.
    try testing.expect(!Hotkey.eql(single, double));
    try testing.expect(Hotkey.eql(double, double2));
}

test "mixed duplicate types should fail" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc, &.{.{ .flags = .{}, .key = 0 }});
    defer hotkey.destroy();

    // Add a command first
    try hotkey.add_process_command("app", "echo app");

    // Try to add forward for same app - should fail
    const key_press = KeyPress{ .flags = .{}, .key = 0x24 };
    const result1 = hotkey.add_process_forward("app", key_press);
    try std.testing.expectError(error.ProcessCommandAlreadyExists, result1);

    // Try to add unbound for same app - should fail
    const result2 = hotkey.add_process_unbound("app");
    try std.testing.expectError(error.ProcessCommandAlreadyExists, result2);

    // Try to add activation for same app - should fail
    const result3 = hotkey.add_process_activation("app", "mode", null);
    try std.testing.expectError(error.ProcessCommandAlreadyExists, result3);

    // Verify original command is still there
    try std.testing.expectEqual(@as(usize, 1), hotkey.getProcessCount());
    const cmd = hotkey.find_command_for_process("app");
    try std.testing.expect(cmd != null);
    try std.testing.expect(cmd.? == .command);
    try std.testing.expectEqualStrings("echo app", cmd.?.command);
}
