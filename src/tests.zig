const std = @import("std");
const testing = std.testing;

// Import our modules
const Hotkey = @import("Hotkey.zig");
const ModifierFlag = @import("Keycodes.zig").ModifierFlag;
const Parser = @import("Parser.zig");
const Mappings = @import("Mappings.zig");
const Mode = @import("Mode.zig");
const Logger = @import("Logger.zig");

test "ModifierFlag basic operations" {
    // Test basic flag creation
    const flag1 = ModifierFlag{ .cmd = true, .shift = true };
    const flag2 = ModifierFlag{ .alt = true };

    // Test merging
    const merged = flag1.merge(flag2);
    try testing.expect(merged.cmd);
    try testing.expect(merged.shift);
    try testing.expect(merged.alt);
    try testing.expect(!merged.control);
}

test "ModifierFlag left/right distinction" {
    const lcmd = ModifierFlag{ .lcmd = true };
    const rcmd = ModifierFlag{ .rcmd = true };

    try testing.expect(lcmd.lcmd);
    try testing.expect(!lcmd.rcmd);
    try testing.expect(!lcmd.cmd);

    try testing.expect(rcmd.rcmd);
    try testing.expect(!rcmd.lcmd);
    try testing.expect(!rcmd.cmd);
}

test "ModifierFlag parsing" {
    // Test that we can get modifiers by string
    const alt_flag = ModifierFlag.get("alt");
    try testing.expect(alt_flag != null);
    try testing.expect(alt_flag.?.alt);

    const lalt_flag = ModifierFlag.get("lalt");
    try testing.expect(lalt_flag != null);
    try testing.expect(lalt_flag.?.lalt);
    try testing.expect(!lalt_flag.?.alt);

    const invalid_flag = ModifierFlag.get("invalid");
    try testing.expect(invalid_flag == null);
}

test "Hotkey creation and equality" {
    const allocator = testing.allocator;

    // Create two identical hotkeys
    var hotkey1 = try Hotkey.create(allocator);
    defer hotkey1.destroy();
    hotkey1.key = 0x31; // '1' key
    hotkey1.flags = ModifierFlag{ .cmd = true };

    var hotkey2 = try Hotkey.create(allocator);
    defer hotkey2.destroy();
    hotkey2.key = 0x31; // '1' key
    hotkey2.flags = ModifierFlag{ .cmd = true };

    // Test equality
    try testing.expect(Hotkey.eql(hotkey1, hotkey2));

    // Change one and test inequality
    hotkey2.key = 0x32; // '2' key
    try testing.expect(!Hotkey.eql(hotkey1, hotkey2));
}

test "Hotkey left/right modifier comparison" {
    const allocator = testing.allocator;

    // Test that general modifier matches specific modifiers
    var general_cmd = try Hotkey.create(allocator);
    defer general_cmd.destroy();
    general_cmd.key = 0x31;
    general_cmd.flags = ModifierFlag{ .cmd = true };

    var left_cmd = try Hotkey.create(allocator);
    defer left_cmd.destroy();
    left_cmd.key = 0x31;
    left_cmd.flags = ModifierFlag{ .lcmd = true };

    var right_cmd = try Hotkey.create(allocator);
    defer right_cmd.destroy();
    right_cmd.key = 0x31;
    right_cmd.flags = ModifierFlag{ .rcmd = true };

    // General modifier should match specific modifiers
    try testing.expect(Hotkey.eql(general_cmd, left_cmd));
    try testing.expect(Hotkey.eql(general_cmd, right_cmd));

    // But specific modifiers should not match each other
    try testing.expect(!Hotkey.eql(left_cmd, right_cmd));
}

test "Mode creation and management" {
    const allocator = testing.allocator;

    var mode = try Mode.init(allocator, "test");
    defer mode.deinit();

    try testing.expectEqualStrings("test", mode.name);
    try testing.expect(!mode.capture);
    try testing.expect(mode.command == null);
}

test "Basic parsing" {
    const allocator = testing.allocator;

    var parser = try Parser.init(allocator);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    // Parse a simple hotkey
    try parser.parse(&mappings, "cmd - a : echo test");

    // Should have a default mode
    const default_mode = mappings.mode_map.get("default");
    try testing.expect(default_mode != null);

    // Should have one hotkey
    const hotkey_count = default_mode.?.hotkey_map.count();
    try testing.expect(hotkey_count == 1);
}

test "Mode declaration parsing" {
    const allocator = testing.allocator;

    var parser = try Parser.init(allocator);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    // Parse mode declaration
    try parser.parse(&mappings, ":: test : echo \"test mode\"");

    // Should have both default and test modes
    try testing.expect(mappings.mode_map.count() == 2);

    const test_mode = mappings.mode_map.get("test");
    try testing.expect(test_mode != null);
    try testing.expectEqualStrings("test", test_mode.?.name);
}

test "Mode switching hotkey" {
    const allocator = testing.allocator;

    var parser = try Parser.init(allocator);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    // Parse mode declaration and mode switching hotkey
    try parser.parse(&mappings,
        \\:: test
        \\cmd - t ; test
    );

    // Should have default and test modes
    try testing.expect(mappings.mode_map.count() == 2);

    // Find the mode switching hotkey in default mode
    const default_mode = mappings.mode_map.get("default");
    try testing.expect(default_mode != null);

    const hotkey_count = default_mode.?.hotkey_map.count();
    try testing.expect(hotkey_count == 1);

    // Check if the hotkey has the activate flag
    var hotkey_iter = default_mode.?.hotkey_map.iterator();
    if (hotkey_iter.next()) |entry| {
        const hotkey = entry.key_ptr.*;
        try testing.expect(hotkey.flags.activate);
    }
}

test "Left/right modifier parsing" {
    const allocator = testing.allocator;

    var parser = try Parser.init(allocator);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    // Parse hotkeys with left/right modifiers
    try parser.parse(&mappings,
        \\lcmd - a : echo "left command"
        \\rcmd - b : echo "right command"
        \\lalt + rshift - c : echo "left alt + right shift"
    );

    const default_mode = mappings.mode_map.get("default");
    try testing.expect(default_mode != null);
    try testing.expect(default_mode.?.hotkey_map.count() == 3);

    // Check that the flags are parsed correctly
    var hotkey_iter = default_mode.?.hotkey_map.iterator();
    var found_lcmd = false;
    var found_rcmd = false;
    var found_mixed = false;

    while (hotkey_iter.next()) |entry| {
        const hotkey = entry.key_ptr.*;
        if (hotkey.flags.lcmd and !hotkey.flags.rcmd and !hotkey.flags.cmd) {
            found_lcmd = true;
        }
        if (hotkey.flags.rcmd and !hotkey.flags.lcmd and !hotkey.flags.cmd) {
            found_rcmd = true;
        }
        if (hotkey.flags.lalt and hotkey.flags.rshift) {
            found_mixed = true;
        }
    }

    try testing.expect(found_lcmd);
    try testing.expect(found_rcmd);
    try testing.expect(found_mixed);
}

test "Process-specific hotkey parsing" {
    const allocator = testing.allocator;

    var parser = try Parser.init(allocator);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    // Parse process-specific hotkey
    try parser.parse(&mappings,
        \\cmd - n [
        \\    "terminal" : echo "terminal command"
        \\    "safari"   : echo "safari command"
        \\    *          : echo "default command"
        \\]
    );

    const default_mode = mappings.mode_map.get("default");
    try testing.expect(default_mode != null);
    try testing.expect(default_mode.?.hotkey_map.count() == 1);

    // Check the hotkey has process-specific commands
    var hotkey_iter = default_mode.?.hotkey_map.iterator();
    if (hotkey_iter.next()) |entry| {
        const hotkey = entry.key_ptr.*;
        try testing.expect(hotkey.process_names.items.len == 2); // terminal and safari
        try testing.expect(hotkey.wildcard_command != null); // default command
    }
}

test "Blacklist parsing" {
    const allocator = testing.allocator;

    var parser = try Parser.init(allocator);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    // Parse blacklist
    try parser.parse(&mappings,
        \\.blacklist [
        \\    "terminal"
        \\    "finder"
        \\]
    );

    try testing.expect(mappings.blacklist.contains("terminal"));
    try testing.expect(mappings.blacklist.contains("finder"));
    try testing.expect(!mappings.blacklist.contains("safari"));
}

test "Shell option parsing" {
    const allocator = testing.allocator;

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    // Default shell should be from environment or /bin/bash
    const initial_shell = mappings.shell;
    try testing.expect(initial_shell.len > 0);

    var parser = try Parser.init(allocator);
    defer parser.deinit();

    // Test parsing shell option
    const config =
        \\.shell "/usr/bin/env zsh"
        \\cmd - a : echo "test"
    ;

    try parser.parse(&mappings, config);

    // Shell should be updated
    try testing.expectEqualStrings("/usr/bin/env zsh", mappings.shell);
}

test "Shell from environment" {
    const allocator = testing.allocator;

    // Test that SHELL env var is respected on init
    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    // Should use SHELL env var if set, otherwise /bin/bash
    if (std.posix.getenv("SHELL")) |env_shell| {
        try testing.expectEqualStrings(env_shell, mappings.shell);
    } else {
        try testing.expectEqualStrings("/bin/bash", mappings.shell);
    }
}

test "Config file resolution" {
    const allocator = testing.allocator;

    // Test getting config file
    const getConfigFile = @import("main.zig").getConfigFile;

    // This should resolve to a path based on environment
    const config_path = try getConfigFile(allocator, "skhdrc");
    defer allocator.free(config_path);

    // Should be one of:
    // - $XDG_CONFIG_HOME/skhd/skhdrc
    // - $HOME/.config/skhd/skhdrc
    // - $HOME/.skhdrc
    // - skhdrc (in current dir)
    try testing.expect(config_path.len > 0);

    // Test that the function returns a valid path
    if (std.posix.getenv("HOME")) |home| {
        // If we have HOME, the path should contain it or be the fallback
        const has_home = std.mem.indexOf(u8, config_path, home) != null;
        const is_fallback = std.mem.eql(u8, config_path, "skhdrc");
        try testing.expect(has_home or is_fallback);
    }
}

test "Logger file paths" {
    const allocator = testing.allocator;

    // Create unique test file
    const test_id = std.crypto.random.int(u32);
    const log_path = try std.fmt.allocPrint(allocator, "/tmp/skhd_test_{d}.log", .{test_id});
    defer allocator.free(log_path);

    // Create logger with unique file in service mode
    var logger = try Logger.initWithPath(allocator, .service, log_path);
    defer logger.deinit();

    // Clean up test file
    defer std.fs.deleteFileAbsolute(log_path) catch {};

    // Verify logger was created
    try testing.expect(logger.log_file != null);

    // Test logging functions
    try logger.logInfo("Test info message", .{});
    try logger.logError("Test error message", .{});
    try logger.logDebug("Test debug message", .{});

    // In service mode, only errors should be logged
    // Info and debug calls should not fail but won't log
}

test "Logger with interactive mode" {
    const allocator = testing.allocator;

    // Create unique test file
    const test_id = std.crypto.random.int(u32);
    const log_path = try std.fmt.allocPrint(allocator, "/tmp/skhd_test_{d}.log", .{test_id});
    defer allocator.free(log_path);

    // Create logger in interactive mode
    var logger = try Logger.initWithPath(allocator, .interactive, log_path);
    defer logger.deinit();

    // Clean up test file
    defer std.fs.deleteFileAbsolute(log_path) catch {};

    // Test various log operations
    try logger.logInfo("Verbose info: {s}", .{"test"});
    try logger.logError("Verbose error: {d}", .{42});
    try logger.logDebug("Verbose debug: {any}", .{true});

    // Test command logging
    try logger.logCommand("echo 'hello'", "hello\nworld\n", "");
    try logger.logCommand("false", "", "command failed\n");
}
