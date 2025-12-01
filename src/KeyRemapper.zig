const std = @import("std");
const c = @import("c.zig");

const KeyRemapper = @This();
const log = std.log.scoped(.key_remapper);

pub const KeyMapping = struct {
    from: u64, // HID usage (0x700000000 | usage)
    to: u64,   // HID usage (0x700000000 | usage)
    
    // Common mappings
    pub const CAPS_TO_F13 = KeyMapping{
        .from = 0x700000039, // Caps Lock
        .to = 0x700000068,   // F13
    };
    
    pub const CAPS_TO_ESCAPE = KeyMapping{
        .from = 0x700000039, // Caps Lock
        .to = 0x700000029,   // Escape
    };
    
    pub const CAPS_TO_CONTROL = KeyMapping{
        .from = 0x700000039, // Caps Lock  
        .to = 0x7000000E0,   // Left Control
    };
};

allocator: std.mem.Allocator,
current_mappings: std.ArrayList(KeyMapping),

pub fn create(allocator: std.mem.Allocator) !*KeyRemapper {
    const self = try allocator.create(KeyRemapper);
    self.* = KeyRemapper{
        .allocator = allocator,
        .current_mappings = std.ArrayList(KeyMapping).init(allocator),
    };
    return self;
}

pub fn destroy(self: *KeyRemapper) void {
    self.current_mappings.deinit();
    self.allocator.destroy(self);
}

// Execute hidutil command
fn executeHidutil(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    
    try argv.append("hidutil");
    try argv.appendSlice(args);
    
    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    
    const result = try child.wait();
    
    if (result.Exited != 0) {
        log.err("hidutil failed: {s}", .{stderr});
        return error.HidutilFailed;
    }
}

// Set a single key mapping
pub fn setKeyMapping(self: *KeyRemapper, mapping: KeyMapping) !void {
    var mappings = [_]KeyMapping{mapping};
    try self.setKeyMappings(&mappings);
}

// Set multiple key mappings
pub fn setKeyMappings(self: *KeyRemapper, mappings: []const KeyMapping) !void {
    // Build JSON for mappings
    var json = std.ArrayList(u8).init(self.allocator);
    defer json.deinit();
    
    try json.appendSlice("{\"UserKeyMapping\":[");
    
    for (mappings, 0..) |mapping, i| {
        if (i > 0) try json.append(',');
        try json.writer().print(
            "{{\"HIDKeyboardModifierMappingSrc\":0x{x},\"HIDKeyboardModifierMappingDst\":0x{x}}}",
            .{ mapping.from, mapping.to }
        );
    }
    
    try json.appendSlice("]}");
    
    // Execute hidutil
    const args = [_][]const u8{ "property", "--set", json.items };
    try executeHidutil(self.allocator, &args);
    
    // Update our tracking
    self.current_mappings.clearAndFree();
    try self.current_mappings.appendSlice(mappings);
    
    log.info("Set {} key mapping(s)", .{mappings.len});
    for (mappings) |mapping| {
        log.info("  0x{x} → 0x{x}", .{ mapping.from & 0xFFFFFFFF, mapping.to & 0xFFFFFFFF });
    }
}

// Clear all key mappings
pub fn clearKeyMappings(self: *KeyRemapper) !void {
    const args = [_][]const u8{ "property", "--set", "{\"UserKeyMapping\":[]}" };
    try executeHidutil(self.allocator, &args);
    
    self.current_mappings.clearAndFree();
    log.info("Cleared all key mappings", .{});
}

// Get current key mappings
pub fn getCurrentMappings(self: *KeyRemapper) ![]KeyMapping {
    const args = [_][]const u8{ "property", "--get", "UserKeyMapping" };
    
    var argv = std.ArrayList([]const u8).init(self.allocator);
    defer argv.deinit();
    
    try argv.append("hidutil");
    try argv.appendSlice(&args);
    
    var child = std.process.Child.init(argv.items, self.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.reader().readAllAlloc(self.allocator, 1024 * 1024);
    defer self.allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(self.allocator, 1024 * 1024);
    defer self.allocator.free(stderr);
    
    const result = try child.wait();
    
    if (result.Exited != 0) {
        return &[_]KeyMapping{};
    }
    
    // Parse the output
    // hidutil returns "(null)" if no mappings
    if (std.mem.eql(u8, std.mem.trim(u8, stdout, " \n"), "(null)")) {
        return &[_]KeyMapping{};
    }
    
    // TODO: Parse JSON output properly
    // For now, we'll trust our internal tracking
    return try self.current_mappings.toOwnedSlice();
}

// Check if Caps Lock is already remapped
pub fn isCapsLockRemapped(self: *KeyRemapper) !bool {
    const output = try self.getCurrentMappingsOutput();
    defer self.allocator.free(output);
    
    // Check if output contains Caps Lock mapping
    // Looking for "HIDKeyboardModifierMappingSrc" : 3221225521 (0x700000039)
    return std.mem.indexOf(u8, output, "3221225521") != null or
           std.mem.indexOf(u8, output, "0x700000039") != null;
}

// Get raw output from hidutil
fn getCurrentMappingsOutput(self: *KeyRemapper) ![]const u8 {
    const args = [_][]const u8{ "property", "--get", "UserKeyMapping" };
    
    var argv = std.ArrayList([]const u8).init(self.allocator);
    defer argv.deinit();
    
    try argv.append("hidutil");
    try argv.appendSlice(&args);
    
    var child = std.process.Child.init(argv.items, self.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.reader().readAllAlloc(self.allocator, 1024 * 1024);
    errdefer self.allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(self.allocator, 1024 * 1024);
    defer self.allocator.free(stderr);
    
    const result = try child.wait();
    
    if (result.Exited != 0) {
        self.allocator.free(stdout);
        return self.allocator.dupe(u8, "(null)");
    }
    
    return stdout;
}

test "KeyRemapper basic operations" {
    const allocator = std.testing.allocator;
    
    const remapper = try KeyRemapper.create(allocator);
    defer remapper.destroy();
    
    // Check if already mapped
    const was_mapped = try remapper.isCapsLockRemapped();
    
    // Test setting a mapping
    try remapper.setKeyMapping(KeyMapping.CAPS_TO_F13);
    
    // Verify it's mapped
    const is_mapped = try remapper.isCapsLockRemapped();
    try std.testing.expect(is_mapped);
    
    // Clear if we set it
    if (!was_mapped) {
        try remapper.clearKeyMappings();
    }
}