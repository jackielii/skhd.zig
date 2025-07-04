const std = @import("std");
const testing = std.testing;

// Import our modules
const Hotkey = @import("HotkeyMultiArrayList.zig");
const ModifierFlag = @import("Keycodes.zig").ModifierFlag;
const Parser = @import("Parser.zig");
const Mappings = @import("Mappings.zig");
const Mode = @import("Mode.zig");
const Skhd = @import("skhd.zig");
const ParseError = @import("ParseError.zig").ParseError;
const print = std.debug.print;
const log = std.log.scoped(.tests);

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

    // General modifier should NOT match specific modifiers in config comparison
    // (This is different from keyboard event matching)
    try testing.expect(!Hotkey.eql(general_cmd, left_cmd));
    try testing.expect(!Hotkey.eql(general_cmd, right_cmd));

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
        try testing.expect(hotkey.getProcessNames().len == 3); // terminal, safari, and *
        // Check that wildcard was added
        const wildcard_cmd = hotkey.find_command_for_process("random_app");
        try testing.expect(wildcard_cmd != null);
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

test "Config reload memory leak test" {
    const allocator = testing.allocator;

    // Create temporary config files
    const test_id = std.crypto.random.int(u32);
    const config_path = try std.fmt.allocPrint(allocator, "/tmp/skhd_test_reload_{d}.skhdrc", .{test_id});
    defer allocator.free(config_path);

    // Write initial config
    {
        const initial_config =
            \\# Initial test config
            \\cmd - a : echo "initial A"
            \\cmd - b : echo "initial B"
            \\:: test_mode
            \\test_mode < cmd - x : echo "test mode X"
        ;

        const file = try std.fs.createFileAbsolute(config_path, .{});
        defer file.close();
        try file.writeAll(initial_config);
    }

    // Clean up config file after test
    defer std.fs.deleteFileAbsolute(config_path) catch {};

    // Initialize skhd with initial config
    var skhd = try Skhd.init(allocator, config_path, false, false);
    defer skhd.deinit();

    // Verify initial state
    try testing.expect(skhd.mappings.mode_map.count() == 2); // default and test_mode
    const default_mode = skhd.mappings.mode_map.get("default");
    try testing.expect(default_mode != null);
    try testing.expect(default_mode.?.hotkey_map.count() == 2); // a and b keys

    // Write modified config
    {
        const modified_config =
            \\# Modified test config
            \\cmd - a : echo "modified A"
            \\cmd - c : echo "new C"
            \\cmd - d : echo "new D"
            \\:: another_mode
            \\another_mode < cmd - y : echo "another mode Y"
            \\.blacklist [
            \\    "terminal"
            \\]
        ;

        const file = std.fs.openFileAbsolute(config_path, .{ .mode = .write_only }) catch unreachable;
        defer file.close();
        try file.setEndPos(0); // Truncate file
        try file.writeAll(modified_config);
    }

    // Reload config
    try skhd.reloadConfig();

    // Verify reloaded state
    try testing.expect(skhd.mappings.mode_map.count() == 2); // default and another_mode
    const reloaded_default = skhd.mappings.mode_map.get("default");
    try testing.expect(reloaded_default != null);
    try testing.expect(reloaded_default.?.hotkey_map.count() == 3); // a, c, and d keys

    // Check that test_mode is gone and another_mode exists
    try testing.expect(skhd.mappings.mode_map.get("test_mode") == null);
    try testing.expect(skhd.mappings.mode_map.get("another_mode") != null);

    // Check blacklist was loaded
    try testing.expect(skhd.mappings.blacklist.contains("terminal"));

    // Test multiple reloads to ensure no memory leaks
    for (0..5) |i| {
        // Modify config again
        const multi_config = try std.fmt.allocPrint(allocator,
            \\# Reload test {d}
            \\cmd - {c} : echo "reload {d}"
        , .{ i, 'a' + @as(u8, @intCast(i)), i });
        defer allocator.free(multi_config);

        const file = std.fs.openFileAbsolute(config_path, .{ .mode = .write_only }) catch unreachable;
        defer file.close();
        try file.setEndPos(0);
        try file.writeAll(multi_config);

        // Reload
        try skhd.reloadConfig();

        // Verify state after each reload
        const mode = skhd.mappings.mode_map.get("default");
        try testing.expect(mode != null);
        try testing.expect(mode.?.hotkey_map.count() == 1);
    }

    // The testing allocator will detect any memory leaks when skhd.deinit() is called
}

test "Config reload preserves current mode" {
    const allocator = testing.allocator;

    // Create temporary config file
    const test_id = std.crypto.random.int(u32);
    const config_path = try std.fmt.allocPrint(allocator, "/tmp/skhd_test_mode_{d}.skhdrc", .{test_id});
    defer allocator.free(config_path);

    // Write config with modes
    {
        const config =
            \\:: default
            \\cmd - a : echo "default A"
            \\
            \\:: special @ : echo "entered special mode"
            \\cmd - t ; special
            \\special < cmd - b : echo "special B"
            \\special < escape ; default
        ;

        const file = try std.fs.createFileAbsolute(config_path, .{});
        defer file.close();
        try file.writeAll(config);
    }

    defer std.fs.deleteFileAbsolute(config_path) catch {};

    // Initialize skhd
    var skhd = try Skhd.init(allocator, config_path, false, false);
    defer skhd.deinit();

    // Switch to special mode
    skhd.current_mode = skhd.mappings.mode_map.getPtr("special");
    try testing.expect(skhd.current_mode != null);
    try testing.expectEqualStrings("special", skhd.current_mode.?.name);

    // Reload config
    try skhd.reloadConfig();

    // Should be back in default mode after reload
    try testing.expect(skhd.current_mode != null);
    try testing.expectEqualStrings("default", skhd.current_mode.?.name);
}

test "Parser error messages" {
    const allocator = testing.allocator;

    var parser = try Parser.init(allocator);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    // Test missing '<' after mode
    parser.clearError();
    const err1 = parser.parse(&mappings, "mymode cmd - a : echo test");
    try testing.expectError(error.ParseErrorOccurred, err1);
    try testing.expect(parser.getError() != null);
    const parse_err1 = parser.getError().?;
    try testing.expect(std.mem.containsAtLeast(u8, parse_err1.message, 1, "Mode 'mymode' not found"));
    try testing.expect(parse_err1.line == 1);

    // Create the mode first, then test missing '<'
    try mappings.put_mode(try Mode.init(allocator, "mymode"));
    parser.clearError();
    const err1b = parser.parse(&mappings, "mymode cmd - a : echo test");
    try testing.expectError(error.ParseErrorOccurred, err1b);
    const parse_err1b = parser.getError().?;
    try testing.expectEqualStrings("Expected '<' after mode identifier", parse_err1b.message);

    // Test unknown mode
    parser.clearError();
    const err2 = parser.parse(&mappings, "foo - b : echo test");
    try testing.expectError(error.ParseErrorOccurred, err2);
    try testing.expect(parser.getError() != null);
    const parse_err2 = parser.getError().?;
    try testing.expect(std.mem.containsAtLeast(u8, parse_err2.message, 1, "Mode 'foo' not found"));

    // Test missing '-' after modifier
    parser.clearError();
    const err3 = parser.parse(&mappings, "cmd b : echo test");
    try testing.expectError(error.ParseErrorOccurred, err3);
    try testing.expect(parser.getError() != null);
    const parse_err3 = parser.getError().?;
    try testing.expectEqualStrings("Expected '-' after modifier", parse_err3.message);

    // Test unknown key
    parser.clearError();
    const err4 = parser.parse(&mappings, "cmd - unknown_key : echo test");
    try testing.expectError(error.ParseErrorOccurred, err4);
    try testing.expect(parser.getError() != null);
    const parse_err4 = parser.getError().?;
    try testing.expectEqualStrings("Expected key, key hex, or literal", parse_err4.message);

    // Test empty process list
    parser.clearError();
    const err5 = parser.parse(&mappings, "cmd - d []");
    try testing.expectError(error.ParseErrorOccurred, err5);
    try testing.expect(parser.getError() != null);
    const parse_err5 = parser.getError().?;
    try testing.expectEqualStrings("Empty process list", parse_err5.message);

    // Test duplicate mode declaration
    parser.clearError();
    const err6 = parser.parse(&mappings, ":: test_mode\n:: test_mode");
    try testing.expectError(error.ParseErrorOccurred, err6);
    try testing.expect(parser.getError() != null);
    const parse_err6 = parser.getError().?;
    try testing.expect(std.mem.containsAtLeast(u8, parse_err6.message, 1, "Mode 'test_mode' already exists"));
    try testing.expect(parse_err6.line == 2);

    // Test unknown option
    parser.clearError();
    const err7 = parser.parse(&mappings, ".unknown_option");
    try testing.expectError(error.ParseErrorOccurred, err7);
    try testing.expect(parser.getError() != null);
    const parse_err7 = parser.getError().?;
    try testing.expect(std.mem.containsAtLeast(u8, parse_err7.message, 1, "Unknown option 'unknown_option'"));
}

test "Parser error message formatting" {

    // Test error formatting without file path
    var err1 = try ParseError.fromPosition(testing.allocator, 5, 10, "Test error message", null);
    defer err1.deinit();
    var buf: [256]u8 = undefined;
    const result1 = try std.fmt.bufPrint(&buf, "{}", .{err1});
    try testing.expectEqualStrings("5:10: error: Test error message", result1);

    // Test error formatting with file path
    var err2 = try ParseError.fromPosition(testing.allocator, 3, 7, "Another error", "test.skhdrc");
    defer err2.deinit();
    const result2 = try std.fmt.bufPrint(&buf, "{}", .{err2});
    try testing.expectEqualStrings("test.skhdrc:3:7: error: Another error", result2);

    // Test error with token text
    const token = @import("Tokenizer.zig").Token{
        .type = .Token_Key,
        .text = "badkey",
        .line = 2,
        .cursor = 15,
    };
    var err3 = try ParseError.fromToken(testing.allocator, token, "Unknown key", "config.skhdrc");
    defer err3.deinit();
    const result3 = try std.fmt.bufPrint(&buf, "{}", .{err3});
    try testing.expectEqualStrings("config.skhdrc:2:15: error: Unknown key near 'badkey'", result3);
}

test "Parser error with multiline input" {
    const allocator = testing.allocator;

    var parser = try Parser.init(allocator);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    // Test error on line 3
    const multiline_config =
        \\# Comment line
        \\cmd - a : echo "valid"
        \\bad - x : echo "error"
        \\cmd - b : echo "another"
    ;

    parser.clearError();
    const err = parser.parse(&mappings, multiline_config);
    try testing.expectError(error.ParseErrorOccurred, err);

    const parse_err = parser.getError().?;
    try testing.expect(std.mem.containsAtLeast(u8, parse_err.message, 1, "Mode 'bad' not found"));
    try testing.expect(parse_err.line == 3);
    try testing.expectEqualStrings("bad", parse_err.token_text.?);
}

test "Hot reload enable/disable" {
    const allocator = testing.allocator;

    // Create temporary config file
    const test_id = std.crypto.random.int(u32);
    const config_path = try std.fmt.allocPrint(allocator, "/tmp/skhd_test_hotload_{d}.skhdrc", .{test_id});
    defer allocator.free(config_path);

    // Write initial config
    {
        const config = "cmd - a : echo \"test A\"";
        const file = try std.fs.createFileAbsolute(config_path, .{});
        defer file.close();
        try file.writeAll(config);
    }

    defer std.fs.deleteFileAbsolute(config_path) catch {};

    // Initialize skhd
    var skhd = try Skhd.init(allocator, config_path, false, false);
    defer skhd.deinit();

    // Test enabling hot reload
    try testing.expect(!skhd.hotload_enabled);
    try skhd.enableHotReload();
    try testing.expect(skhd.hotload_enabled);
    try testing.expect(skhd.hotloader != null);

    // Test disabling hot reload
    skhd.disableHotReload();
    try testing.expect(!skhd.hotload_enabled);
    try testing.expect(skhd.hotloader == null);

    // Test re-enabling
    try skhd.enableHotReload();
    try testing.expect(skhd.hotload_enabled);

    // Double enable should be safe
    try skhd.enableHotReload();
    try testing.expect(skhd.hotload_enabled);
}

test "modifier matching - general modifiers match specific ones" {
    const allocator = std.testing.allocator;

    // Create test config
    const config_path = "/tmp/skhd_test_modifier_matching.txt";
    {
        const config =
            \\# Test modifier matching
            \\alt - a : echo "alt - a"
            \\lalt - b : echo "lalt - b"
            \\cmd + shift - c : echo "cmd + shift - c"
            \\lcmd + lshift - d : echo "lcmd + lshift - d"
        ;
        const file = try std.fs.createFileAbsolute(config_path, .{});
        defer file.close();
        try file.writeAll(config);
    }
    defer std.fs.deleteFileAbsolute(config_path) catch {};

    var skhd = try Skhd.init(allocator, config_path, false, false);
    defer skhd.deinit();

    // Get default mode
    const mode = skhd.mappings.mode_map.get("default").?;

    // Test 1: Config "alt - a" should be found with keyboard "lalt - a"
    {
        const keyboard_key = Hotkey.KeyPress{
            .flags = ModifierFlag{ .lalt = true },
            .key = 0, // 'a' key
        };

        // Find matching hotkey using our lookup abstraction
        const found = skhd.findHotkeyInMode(&mode, keyboard_key);

        try testing.expect(found != null);
        try testing.expect(found.?.flags.alt);
        try testing.expect(!found.?.flags.lalt);
    }

    // Test 2: Config "lalt - b" should NOT be found with keyboard "ralt - b"
    {
        const keyboard_key = Hotkey.KeyPress{
            .flags = ModifierFlag{ .ralt = true },
            .key = 11, // 'b' key
        };

        // Find matching hotkey using our lookup abstraction
        const found = skhd.findHotkeyInMode(&mode, keyboard_key);

        try testing.expect(found == null);
    }

    // Test 3: Config "cmd + shift - c" should match "lcmd + lshift - c"
    {
        const keyboard_key = Hotkey.KeyPress{
            .flags = ModifierFlag{ .lcmd = true, .lshift = true },
            .key = 8, // 'c' key
        };

        // Find matching hotkey using our lookup abstraction
        const found = skhd.findHotkeyInMode(&mode, keyboard_key);

        try testing.expect(found != null);
        try testing.expect(found.?.flags.cmd);
        try testing.expect(found.?.flags.shift);
    }
}

test "keyboard lalt should match config alt" {
    const allocator = std.testing.allocator;

    // Create test config with just "alt - a"
    const config_path = "/tmp/skhd_test_lalt_matches_alt.txt";
    {
        const config = "alt - a : echo \"alt - a pressed\"";
        const file = try std.fs.createFileAbsolute(config_path, .{});
        defer file.close();
        try file.writeAll(config);
    }
    defer std.fs.deleteFileAbsolute(config_path) catch {};

    var skhd = try Skhd.init(allocator, config_path, false, false);
    defer skhd.deinit();

    // Get default mode
    const mode = skhd.mappings.mode_map.get("default").?;

    // Test: Keyboard "lalt - a" should match config "alt - a"
    {
        const keyboard_key = Hotkey.KeyPress{
            .flags = ModifierFlag{ .lalt = true },
            .key = 0, // 'a' key
        };

        // Find matching hotkey using our lookup abstraction
        const found = skhd.findHotkeyInMode(&mode, keyboard_key);

        if (found == null) {
            std.debug.print("Test failed: Could not find hotkey for lalt - a\n", .{});
            std.debug.print("Looking for keyboard_key: flags={any}, key={d}\n", .{ keyboard_key.flags, keyboard_key.key });
            std.debug.print("Available hotkeys in map:\n", .{});
            var it = mode.hotkey_map.iterator();
            while (it.next()) |entry| {
                const hotkey = entry.key_ptr.*;
                std.debug.print("  config hotkey: flags={any}, key={d}\n", .{ hotkey.flags, hotkey.key });
            }
        }
        try testing.expect(found != null);
        try testing.expect(found.?.flags.alt);
        try testing.expect(!found.?.flags.lalt);
    }

    // Also test ralt should match
    {
        const keyboard_key = Hotkey.KeyPress{
            .flags = ModifierFlag{ .ralt = true },
            .key = 0, // 'a' key
        };

        const ctx = Hotkey.KeyboardLookupContext{};
        const found = mode.hotkey_map.getKeyAdapted(keyboard_key, ctx);

        try testing.expect(found != null);
        try testing.expect(found.?.flags.alt);
        try testing.expect(!found.?.flags.ralt);
    }

    // And general alt should also match
    {
        const keyboard_key = Hotkey.KeyPress{
            .flags = ModifierFlag{ .alt = true },
            .key = 0, // 'a' key
        };

        const ctx = Hotkey.KeyboardLookupContext{};
        const found = mode.hotkey_map.getKeyAdapted(keyboard_key, ctx);

        try testing.expect(found != null);
        try testing.expect(found.?.flags.alt);
    }
}

test "find_command_for_process function with process matching" {
    const allocator = std.testing.allocator;

    // Create a hotkey with some process names
    var hotkey = try Hotkey.create(allocator);
    defer hotkey.destroy();

    try hotkey.add_process_mapping("chrome", Hotkey.ProcessCommand{ .command = "echo chrome" });
    try hotkey.add_process_mapping("firefox", Hotkey.ProcessCommand{ .command = "echo firefox" });
    try hotkey.add_process_mapping("whatsapp", Hotkey.ProcessCommand{ .command = "echo whatsapp" });
    try hotkey.add_process_mapping("*", Hotkey.ProcessCommand{ .command = "echo wildcard" });

    // Test finding existing processes (case insensitive)
    const chrome_cmd = hotkey.find_command_for_process("Chrome");
    try testing.expect(chrome_cmd != null);
    try testing.expectEqualStrings("echo chrome", chrome_cmd.?.command);

    const firefox_cmd = hotkey.find_command_for_process("FIREFOX");
    try testing.expect(firefox_cmd != null);
    try testing.expectEqualStrings("echo firefox", firefox_cmd.?.command);

    // Test wildcard fallback
    const notepad_cmd = hotkey.find_command_for_process("notepad");
    try testing.expect(notepad_cmd != null);
    try testing.expectEqualStrings("echo wildcard", notepad_cmd.?.command);
}

test "process group variables" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    // Test .define directive and @group_name usage
    const content =
        \\.define native_apps ["kitty", "wezterm", "chrome"]
        \\home [
        \\    @native_apps ~
        \\    *            | cmd - left
        \\]
    ;

    try parser.parse(&mappings, content);

    // Check that process group was created
    try testing.expect(mappings.process_groups.contains("native_apps"));
    const group = mappings.process_groups.get("native_apps").?;
    try testing.expectEqual(@as(usize, 3), group.len);
    try testing.expectEqualStrings("kitty", group[0]);
    try testing.expectEqualStrings("wezterm", group[1]);
    try testing.expectEqualStrings("chrome", group[2]);

    // Check that hotkey was created with processes from the group
    try testing.expectEqual(@as(usize, 1), mappings.hotkey_map.count());
    var it = mappings.hotkey_map.iterator();
    const entry = it.next().?;
    const hotkey = entry.key_ptr.*;

    // Should have 3 process names from the group + 1 wildcard
    const process_names = hotkey.getProcessNames();
    try testing.expectEqual(@as(usize, 4), process_names.len);
    try testing.expectEqualStrings("kitty", process_names[0]);
    try testing.expectEqualStrings("wezterm", process_names[1]);
    try testing.expectEqualStrings("chrome", process_names[2]);
    try testing.expectEqualStrings("*", process_names[3]);

    // 3 unbound (native_apps) + 1 forwarded (wildcard)
    const stats = hotkey.mappings.countCommandTypes();
    try testing.expectEqual(@as(usize, 0), stats.commands);
    try testing.expectEqual(@as(usize, 1), stats.forwarded); // wildcard forwards
    try testing.expectEqual(@as(usize, 3), stats.unbound);

    // Wildcard should forward to cmd - left
    const wildcard_result = hotkey.find_command_for_process("random_app");
    try testing.expect(wildcard_result != null);
    try testing.expect(wildcard_result.? == .forwarded);
    const forward_key = wildcard_result.?.forwarded;
    try testing.expect(forward_key.flags.cmd);
    try testing.expectEqual(@as(u32, 0x7B), forward_key.key); // left arrow
}

test "multiple process groups and reuse" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    // Test multiple groups and reusing them
    const content =
        \\.define terminal_apps ["kitty", "wezterm", "terminal"]
        \\.define browser_apps ["chrome", "safari", "firefox"]
        \\.define native_apps ["kitty", "wezterm", "chrome", "whatsapp"]
        \\
        \\# Delete word
        \\ctrl - backspace [
        \\    @terminal_apps ~
        \\    *              | alt - backspace
        \\]
        \\
        \\# Move word
        \\ctrl - left [
        \\    @terminal_apps ~
        \\    *              | alt - left
        \\]
        \\
        \\# Home key
        \\home [
        \\    @native_apps ~
        \\    *            | cmd - left
        \\]
    ;

    try parser.parse(&mappings, content);

    // Check that all process groups were created
    try testing.expect(mappings.process_groups.contains("terminal_apps"));
    try testing.expect(mappings.process_groups.contains("browser_apps"));
    try testing.expect(mappings.process_groups.contains("native_apps"));

    // Check group contents
    const terminal_group = mappings.process_groups.get("terminal_apps").?;
    try testing.expectEqual(@as(usize, 3), terminal_group.len);

    const browser_group = mappings.process_groups.get("browser_apps").?;
    try testing.expectEqual(@as(usize, 3), browser_group.len);

    const native_group = mappings.process_groups.get("native_apps").?;
    try testing.expectEqual(@as(usize, 4), native_group.len);

    // Should have 3 hotkeys
    try testing.expectEqual(@as(usize, 3), mappings.hotkey_map.count());
}

test "Mode capture behavior" {
    const allocator = testing.allocator;

    var parser = try Parser.init(allocator);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    // Test mode declaration with capture
    const capture_config =
        \\:: resize @ : echo "Entering resize mode"
        \\resize < h : yabai -m window --resize left:-20:0
        \\resize < l : yabai -m window --resize right:20:0 
        \\resize < escape ; default
    ;

    try parser.parse(&mappings, capture_config);

    // Check that resize mode was created with capture enabled
    const resize_mode = mappings.mode_map.get("resize").?;
    try testing.expect(resize_mode.capture);
    try testing.expectEqualStrings("echo \"Entering resize mode\"", resize_mode.command.?);

    // Test mode declaration without capture
    const no_capture_config =
        \\:: normal : echo "Normal mode"
        \\normal < a : echo "action a"
    ;

    var parser2 = try Parser.init(allocator);
    defer parser2.deinit();

    var mappings2 = try Mappings.init(allocator);
    defer mappings2.deinit();

    try parser2.parse(&mappings2, no_capture_config);

    // Check that normal mode was created without capture
    const normal_mode = mappings2.mode_map.get("normal").?;
    try testing.expect(!normal_mode.capture);
    try testing.expectEqualStrings("echo \"Normal mode\"", normal_mode.command.?);
}

test "Command definitions - simple command" {
    const allocator = testing.allocator;
    var parser = try Parser.init(allocator);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    const config =
        \\.define focus_west : yabai -m window --focus west
        \\cmd - h : @focus_west
    ;

    try parser.parse(&mappings, config);

    // Check command definition was stored
    try testing.expect(mappings.command_defs.contains("focus_west"));
    const cmd_def = mappings.command_defs.get("focus_west").?;
    try testing.expectEqualStrings("yabai -m window --focus west", cmd_def.template);
    try testing.expectEqual(@as(u8, 0), cmd_def.max_placeholder);

    // Check hotkey has expanded command
    var it = mappings.hotkey_map.iterator();
    const entry = it.next().?;
    const hotkey = entry.key_ptr.*;

    const commands = hotkey.getCommands();
    try testing.expectEqual(@as(usize, 1), commands.len);
    try testing.expectEqualStrings("yabai -m window --focus west", commands[0].command);
}

test "Command definitions - with single placeholder" {
    const allocator = testing.allocator;
    var parser = try Parser.init(allocator);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    const config =
        \\.define yabai_focus : yabai -m window --focus {{1}}
        \\cmd - h : @yabai_focus("west")
        \\cmd - l : @yabai_focus("east")
    ;

    try parser.parse(&mappings, config);

    // Check command definition
    const cmd_def = mappings.command_defs.get("yabai_focus").?;
    try testing.expectEqualStrings("yabai -m window --focus {{1}}", cmd_def.template);
    try testing.expectEqual(@as(u8, 1), cmd_def.max_placeholder);

    // Find hotkeys and check their commands
    var hotkey_count: usize = 0;
    var it = mappings.hotkey_map.iterator();
    while (it.next()) |entry| {
        const hotkey = entry.key_ptr.*;
        const commands = hotkey.getCommands();

        if (hotkey.key == 4) { // 'h' key
            try testing.expectEqualStrings("yabai -m window --focus west", commands[0].command);
            hotkey_count += 1;
        } else if (hotkey.key == 37) { // 'l' key
            try testing.expectEqualStrings("yabai -m window --focus east", commands[0].command);
            hotkey_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), hotkey_count);
}

test "Command definitions - multiple placeholders" {
    const allocator = testing.allocator;
    var parser = try Parser.init(allocator);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    const config =
        \\.define window_action : yabai -m window --{{1}} {{2}}
        \\cmd - h : @window_action("focus", "west")
    ;

    try parser.parse(&mappings, config);

    // Check command definition
    const cmd_def = mappings.command_defs.get("window_action").?;
    try testing.expectEqual(@as(u8, 2), cmd_def.max_placeholder);

    // Check expanded command
    var it = mappings.hotkey_map.iterator();
    const entry = it.next().?;
    const hotkey = entry.key_ptr.*;
    const commands = hotkey.getCommands();
    try testing.expectEqualStrings("yabai -m window --focus west", commands[0].command);
}

test "Command definitions - repeated placeholder" {
    const allocator = testing.allocator;
    var parser = try Parser.init(allocator);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    const config =
        \\.define toggle_app : yabai -m window --toggle {{1}} || open -a "{{1}}"
        \\cmd - m : @toggle_app("Music")
    ;

    try parser.parse(&mappings, config);

    // Check expanded command
    var it = mappings.hotkey_map.iterator();
    const entry = it.next().?;
    const hotkey = entry.key_ptr.*;
    const commands = hotkey.getCommands();
    try testing.expectEqualStrings("yabai -m window --toggle Music || open -a \"Music\"", commands[0].command);
}

test "Command definitions - in process list" {
    const allocator = testing.allocator;
    var parser = try Parser.init(allocator);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    const config =
        \\.define echo_test : echo "{{1}}"
        \\cmd - a [
        \\    "terminal" : @echo_test("terminal app")
        \\    * : @echo_test("other app")
        \\]
    ;

    try parser.parse(&mappings, config);

    // Check hotkey has correct commands
    var it = mappings.hotkey_map.iterator();
    const entry = it.next().?;
    const hotkey = entry.key_ptr.*;

    const process_names = hotkey.getProcessNames();
    const commands = hotkey.getCommands();

    try testing.expectEqual(@as(usize, 2), process_names.len);

    // Find and verify each process command
    for (process_names, commands) |name, cmd| {
        if (std.mem.eql(u8, name, "terminal")) {
            try testing.expectEqualStrings("echo \"terminal app\"", cmd.command);
        } else if (std.mem.eql(u8, name, "*")) {
            try testing.expectEqualStrings("echo \"other app\"", cmd.command);
        }
    }
}

test "Command definitions - mode declaration" {
    const allocator = testing.allocator;
    var parser = try Parser.init(allocator);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    const config =
        \\.define mode_cmd : echo "Entering {{1}} mode"
        \\:: test_mode : @mode_cmd("test")
    ;

    try parser.parse(&mappings, config);

    // Check mode has expanded command
    const mode = mappings.mode_map.get("test_mode").?;
    try testing.expectEqualStrings("echo \"Entering test mode\"", mode.command.?);
}

test "Command definitions - with escaped quotes" {
    const allocator = testing.allocator;
    var parser = try Parser.init(allocator);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    const config =
        \\.define notify : osascript -e 'display notification "{{1}}" with title "{{2}}"'
        \\cmd - n : @notify("Hello \"World\"", "Test \"Message\"")
    ;

    try parser.parse(&mappings, config);

    // Check expanded command has properly escaped quotes
    var it = mappings.hotkey_map.iterator();
    const entry = it.next().?;
    const hotkey = entry.key_ptr.*;
    const commands = hotkey.getCommands();
    try testing.expectEqualStrings("osascript -e 'display notification \"Hello \"World\"\" with title \"Test \"Message\"\"'", commands[0].command);
}
