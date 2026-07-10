const std = @import("std");
const Mode = @import("Mode.zig");
const Hotkey = @import("Hotkey.zig");
const utils = @import("utils.zig");
const log = std.log.scoped(.mappings);

allocator: std.mem.Allocator,
io: std.Io,
mode_map: std.StringHashMapUnmanaged(Mode) = .empty,
blacklist: std.StringHashMapUnmanaged(void) = .empty,
shell: [:0]const u8,
loaded_files: std.ArrayListUnmanaged([]const u8) = .empty,
// Extra PATH entries declared via `.path` directives. Prepended to PATH at
// startup so commands launched by hotkeys can find user-installed tools that
// aren't in the shell-inherited PATH (e.g. mise/asdf/nvm shims).
paths: std.ArrayListUnmanaged([]const u8) = .empty,
// Track all hotkeys for cleanup (hotkeys can belong to multiple modes)
hotkeys: std.ArrayListUnmanaged(*Hotkey) = .empty,
// Device aliases declared via `.device <name> <vendor> <product>`. Empty
// when the user hasn't opted into per-device matching, in which case the
// IOHIDManager monitor is never started.
device_aliases: std.StringHashMapUnmanaged(DeviceAlias) = .empty,
// HID-level remaps declared via `.remap <src> [device <alias>] : <dst>`.
// Owned by Mappings — strings are duped on insert, freed in deinit.
remaps: std.ArrayListUnmanaged(RemapDecl) = .empty,
// Tap-hold declarations from the block form of `.remap`. Distinct from
// `remaps` so the runtime knows which keys need a state machine vs a
// pure HID-level remap.
tapholds: std.ArrayListUnmanaged(TapHoldDecl) = .empty,

const Mappings = @This();

pub const DeviceAlias = struct {
    vendor: u32,
    product: u32,
};

pub const RemapDecl = struct {
    /// HID usage byte (page implied = 0x07 keyboard) of the source key.
    src_usage: u32,
    /// HID usage byte of the destination key.
    dst_usage: u32,
    /// Device alias name. Owned by Mappings (duped on insert, freed in
    /// deinit). Required for v1 — global remaps are not supported.
    device_alias: []const u8,
};

pub const TapHoldDecl = struct {
    /// HID usage byte of the physical key being intercepted (caps_lock,
    /// space, etc.).
    src_usage: u32,
    /// HID usage byte of the action emitted on a quick tap (e.g.,
    /// escape).
    tap_usage: u32,
    /// HID usage byte of the action committed on hold (e.g., lctrl).
    /// Zero when `hold_layer` is set instead.
    hold_usage: u32 = 0,
    /// Mode name to push on hold (e.g. "fn_layer"). null when this
    /// rule's hold action is a HID usage. Owned by Mappings (duped
    /// on insert, freed in deinit).
    hold_layer: ?[]const u8 = null,
    /// Required device alias (same rationale as RemapDecl). Owned.
    device_alias: []const u8,
    /// Tap-vs-hold decision deadline in milliseconds. Default 200 if
    /// unspecified by the user.
    timeout_ms: u32 = 200,
    /// QMK PERMISSIVE_HOLD: nested-tap (other key down + up) inside the
    /// hold key's press commits to hold even before the timeout.
    permissive_hold: bool = true,
    /// QMK HOLD_ON_OTHER_KEY_PRESS: any other key down commits to hold
    /// immediately. Stronger than permissive_hold; off by default.
    hold_on_other_key_press: bool = false,
    /// QMK RETRO_TAPPING: when held past timeout with no other key
    /// pressed, emit the tap action on release anyway.
    retro_tap: bool = false,
};

pub fn init(alloc: std.mem.Allocator, io: std.Io) !Mappings {
    const default_shell = "/bin/bash";
    const shell = if (@import("utils.zig").getenv("SHELL")) |env|
        try alloc.dupeZ(u8, env)
    else
        try alloc.dupeZ(u8, default_shell);

    return Mappings{
        .shell = shell,
        .allocator = alloc,
        .io = io,
    };
}

pub fn deinit(self: *Mappings) void {
    // First destroy all hotkeys (must be done before destroying modes)
    for (self.hotkeys.items) |hotkey| {
        hotkey.destroy();
    }
    self.hotkeys.deinit(self.allocator);

    {
        var it = self.mode_map.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            kv.value_ptr.*.deinit();
        }
        self.mode_map.deinit(self.allocator);
    }
    {
        var it = self.blacklist.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.blacklist.deinit(self.allocator);
    }
    {
        var it = self.device_aliases.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.device_aliases.deinit(self.allocator);
    }
    for (self.remaps.items) |r| self.allocator.free(r.device_alias);
    self.remaps.deinit(self.allocator);
    for (self.tapholds.items) |t| {
        self.allocator.free(t.device_alias);
        if (t.hold_layer) |l| self.allocator.free(l);
    }
    self.tapholds.deinit(self.allocator);
    self.allocator.free(self.shell);

    // Free loaded file paths
    for (self.loaded_files.items) |file_path| {
        self.allocator.free(file_path);
    }
    self.loaded_files.deinit(self.allocator);

    for (self.paths.items) |path| {
        self.allocator.free(path);
    }
    self.paths.deinit(self.allocator);

    self.* = undefined;
}

pub fn add_hotkey(self: *Mappings, hotkey: *Hotkey) !void {
    // First try to add to all modes
    var it = hotkey.mode_list.iterator();
    while (it.next()) |kv| {
        const mode = kv.key_ptr.*;
        try mode.add_hotkey(hotkey);
    }

    // Only track the hotkey after successful addition to all modes
    try self.hotkeys.append(self.allocator, hotkey);
}

pub fn set_shell(self: *Mappings, shell: []const u8) !void {
    self.allocator.free(self.shell);
    self.shell = try self.allocator.dupeZ(u8, shell);
}

pub fn add_blacklist(self: *Mappings, key: []const u8) !void {
    // Stored lowercased: runtime lookup compares against the lowercased
    // frontmost-app name from CarbonEvent
    const owned = try std.ascii.allocLowerString(self.allocator, key);
    errdefer self.allocator.free(owned);
    if (self.blacklist.contains(owned)) {
        return error.BlacklistEntryAlreadyExists;
    }
    try self.blacklist.put(self.allocator, owned, void{});
}

pub fn add_device_alias(self: *Mappings, name: []const u8, vendor: u32, product: u32) !void {
    if (self.device_aliases.contains(name)) {
        return error.DeviceAliasAlreadyExists;
    }
    const owned = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(owned);
    try self.device_aliases.put(self.allocator, owned, .{ .vendor = vendor, .product = product });
}

pub fn add_remap(self: *Mappings, src_usage: u32, dst_usage: u32, device_alias: []const u8) !void {
    // Same source key for the same device cannot be remapped twice.
    if (self.findRemapOrTaphold(src_usage, device_alias)) {
        return error.RemapConflict;
    }
    const owned_alias = try self.allocator.dupe(u8, device_alias);
    errdefer self.allocator.free(owned_alias);
    try self.remaps.append(self.allocator, .{
        .src_usage = src_usage,
        .dst_usage = dst_usage,
        .device_alias = owned_alias,
    });
}

pub fn add_taphold(self: *Mappings, decl: TapHoldDecl) !void {
    if (self.findRemapOrTaphold(decl.src_usage, decl.device_alias)) {
        return error.RemapConflict;
    }
    const owned_alias = try self.allocator.dupe(u8, decl.device_alias);
    errdefer self.allocator.free(owned_alias);
    const owned_layer: ?[]const u8 = if (decl.hold_layer) |l|
        try self.allocator.dupe(u8, l)
    else
        null;
    errdefer if (owned_layer) |l| self.allocator.free(l);
    var d = decl;
    d.device_alias = owned_alias;
    d.hold_layer = owned_layer;
    try self.tapholds.append(self.allocator, d);
}

/// True if (src_usage, device_alias) is already claimed by a `.remap`
/// or `.remap { ... }` block. Used by both add_remap and add_taphold to
/// reject ambiguous configurations like a colon-form and a block-form
/// targeting the same physical key on the same device.
fn findRemapOrTaphold(self: *const Mappings, src_usage: u32, device_alias: []const u8) bool {
    for (self.remaps.items) |existing| {
        if (existing.src_usage == src_usage and std.mem.eql(u8, existing.device_alias, device_alias)) return true;
    }
    for (self.tapholds.items) |existing| {
        if (existing.src_usage == src_usage and std.mem.eql(u8, existing.device_alias, device_alias)) return true;
    }
    return false;
}

/// Append an entry from a `.path` directive. Caller passes the
/// already-expanded absolute path; expansion (e.g. `~` → `$HOME`) happens at
/// parse time so the stored value is what setenv will use directly.
pub fn add_path(self: *Mappings, path: []const u8) !void {
    const owned = try self.allocator.dupe(u8, path);
    errdefer self.allocator.free(owned);
    try self.paths.append(self.allocator, owned);
}


pub fn format(self: Mappings, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("Mappings {");
    try writer.writeAll("\n  mode_map: {");
    {
        var it = self.mode_map.iterator();
        while (it.next()) |kv| {
            utils.indentPrint(self.allocator, writer, "    ", "\n{f}", kv.value_ptr.*) catch return error.WriteFailed;
        }
    }
    try writer.writeAll("\n  }");
    try writer.writeAll("\n  blacklist: {");
    {
        var it = self.blacklist.keyIterator();
        while (it.next()) |key| {
            try writer.print("\n    {s}", .{key.*});
        }
    }
    try writer.writeAll("\n  }");
    try writer.writeAll("\n}");
}

pub fn get_mode_or_create_default(self: *Mappings, mode_name: []const u8) !?*Mode {
    if (std.mem.eql(u8, mode_name, "default")) {
        const key = try self.allocator.dupe(u8, mode_name);
        errdefer self.allocator.free(key);
        const mode_value = try self.mode_map.getOrPut(self.allocator, key);
        if (mode_value.found_existing) {
            defer self.allocator.free(key);
            return mode_value.value_ptr;
        }
        const mode = try Mode.init(self.allocator, key);
        mode_value.value_ptr.* = mode;
        return mode_value.value_ptr;
    }
    return self.mode_map.getPtr(mode_name);
}

pub fn get_or_create_mode(self: *Mappings, mode_name: []const u8) !*Mode {
    const key = try self.allocator.dupe(u8, mode_name);
    errdefer self.allocator.free(key);
    const mode_value = try self.mode_map.getOrPut(self.allocator, key);
    if (mode_value.found_existing) {
        defer self.allocator.free(key);
        return mode_value.value_ptr;
    }
    const mode = try Mode.init(self.allocator, key);
    mode_value.value_ptr.* = mode;
    return mode_value.value_ptr;
}

pub fn put_mode(self: *Mappings, mode: Mode) !void {
    if (self.mode_map.contains(mode.name)) {
        return error.ModeAlreadyExists;
    }
    const key = try self.allocator.dupe(u8, mode.name);
    try self.mode_map.put(self.allocator, key, mode);
}

test "get_mode default" {
    const alloc = std.testing.allocator;
    var mappings = try Mappings.init(alloc, std.testing.io);
    _ = try mappings.get_mode_or_create_default("default");
    _ = try mappings.get_mode_or_create_default("default");
    _ = try mappings.get_mode_or_create_default("xxx");
    _ = try mappings.get_mode_or_create_default("yyy");
    try std.testing.expectEqual(mappings.mode_map.count(), 1);
    defer mappings.deinit();
}

test "format" {
    const alloc = std.testing.allocator;
    var mappings = try Mappings.init(alloc, std.testing.io);
    defer mappings.deinit();
    const mode = try mappings.get_mode_or_create_default("default");
    // Just verify the formatting doesn't crash
    const formatted = try std.fmt.allocPrint(alloc, "{}", .{mappings});
    defer alloc.free(formatted);
    try std.testing.expect(formatted.len > 0);
    try std.testing.expect(mode != null);
}

test "add_taphold rejects collision with prior .remap on same src+device" {
    const alloc = std.testing.allocator;
    var mappings = try Mappings.init(alloc, std.testing.io);
    defer mappings.deinit();

    try mappings.add_remap(0x39, 0xE0, "builtin");
    const result = mappings.add_taphold(.{
        .src_usage = 0x39,
        .tap_usage = 0x29,
        .hold_usage = 0xE0,
        .device_alias = "builtin",
    });
    try std.testing.expectError(error.RemapConflict, result);
}

test "add_taphold accepts distinct src or distinct device" {
    const alloc = std.testing.allocator;
    var mappings = try Mappings.init(alloc, std.testing.io);
    defer mappings.deinit();

    try mappings.add_taphold(.{
        .src_usage = 0x39, // caps_lock
        .tap_usage = 0x29, // escape
        .hold_usage = 0xE0, // lctrl
        .device_alias = "builtin",
        .timeout_ms = 120,
    });
    // Same key, different device — fine.
    try mappings.add_taphold(.{
        .src_usage = 0x39,
        .tap_usage = 0x29,
        .hold_usage = 0xE0,
        .device_alias = "hhkb",
    });
    // Different key, same device — fine.
    try mappings.add_taphold(.{
        .src_usage = 0x2C, // space
        .tap_usage = 0x2C,
        .hold_usage = 0xE2, // lalt
        .device_alias = "builtin",
        .timeout_ms = 300,
        .retro_tap = true,
    });
    try std.testing.expectEqual(@as(usize, 3), mappings.tapholds.items.len);
    try std.testing.expectEqual(@as(u32, 120), mappings.tapholds.items[0].timeout_ms);
    try std.testing.expectEqual(true, mappings.tapholds.items[2].retro_tap);
}

test "add_remap returns error on duplicate src+device" {
    const alloc = std.testing.allocator;
    var mappings = try Mappings.init(alloc, std.testing.io);
    defer mappings.deinit();

    try mappings.add_remap(0x39, 0xE0, "builtin"); // caps_lock -> lctrl on builtin
    // Same source on a different device is fine.
    try mappings.add_remap(0x39, 0xE0, "hhkb");
    try std.testing.expectEqual(@as(usize, 2), mappings.remaps.items.len);
    // Same source + same device is a conflict.
    const result = mappings.add_remap(0x39, 0xE1, "builtin");
    try std.testing.expectError(error.RemapConflict, result);
    try std.testing.expectEqual(@as(usize, 2), mappings.remaps.items.len);
}

test "add_device_alias returns error on duplicate" {
    const alloc = std.testing.allocator;
    var mappings = try Mappings.init(alloc, std.testing.io);
    defer mappings.deinit();

    try mappings.add_device_alias("builtin", 0x05AC, 0x0342);

    const result = mappings.add_device_alias("builtin", 0x04FE, 0x0021);
    try std.testing.expectError(error.DeviceAliasAlreadyExists, result);

    const entry = mappings.device_aliases.get("builtin").?;
    try std.testing.expectEqual(@as(u32, 0x05AC), entry.vendor);
    try std.testing.expectEqual(@as(u32, 0x0342), entry.product);
    try std.testing.expectEqual(@as(usize, 1), mappings.device_aliases.count());
}

test "add_blacklist returns error on duplicate" {
    const alloc = std.testing.allocator;
    var mappings = try Mappings.init(alloc, std.testing.io);
    defer mappings.deinit();

    // First add should succeed
    try mappings.add_blacklist("firefox");

    // Duplicate should fail
    const result = mappings.add_blacklist("firefox");
    try std.testing.expectError(error.BlacklistEntryAlreadyExists, result);

    // Verify the original entry is still there
    try std.testing.expect(mappings.blacklist.contains("firefox"));
    try std.testing.expectEqual(@as(usize, 1), mappings.blacklist.count());
}

test "add_blacklist normalizes entries to lowercase" {
    const alloc = std.testing.allocator;
    var mappings = try Mappings.init(alloc, std.testing.io);
    defer mappings.deinit();

    // Runtime lookup uses the lowercased frontmost-app name (CarbonEvent),
    // so entries must be stored lowercased regardless of config casing
    try mappings.add_blacklist("VMware Fusion");
    try std.testing.expect(mappings.blacklist.contains("vmware fusion"));

    // Duplicate detection must also be case-insensitive
    const result = mappings.add_blacklist("vmware FUSION");
    try std.testing.expectError(error.BlacklistEntryAlreadyExists, result);
    try std.testing.expectEqual(@as(usize, 1), mappings.blacklist.count());
}

test "put_mode returns error on duplicate" {
    const alloc = std.testing.allocator;
    var mappings = try Mappings.init(alloc, std.testing.io);
    defer mappings.deinit();

    // Create and add a mode
    const mode1 = try Mode.init(alloc, "test_mode");
    try mappings.put_mode(mode1);

    // Try to add another mode with the same name
    var mode2 = try Mode.init(alloc, "test_mode");
    defer mode2.deinit(); // We need to clean this up since put_mode will fail

    const result = mappings.put_mode(mode2);
    try std.testing.expectError(error.ModeAlreadyExists, result);

    // Verify the original mode is still there
    try std.testing.expect(mappings.mode_map.contains("test_mode"));
    try std.testing.expectEqual(@as(usize, 1), mappings.mode_map.count());
}
