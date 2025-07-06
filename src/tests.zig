const std = @import("std");
const testing = std.testing;

// Import our modules
const Hotkey = @import("Hotkey.zig");
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

    try hotkey.add_process_mapping("chrome", .{ .command = "echo chrome" });
    try hotkey.add_process_mapping("firefox", .{ .command = "echo firefox" });
    try hotkey.add_process_mapping("whatsapp", .{ .command = "echo whatsapp" });
    try hotkey.add_process_mapping("*", .{ .command = "echo wildcard" });

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
    try testing.expect(parser.process_groups.contains("terminal_apps"));
    try testing.expect(parser.process_groups.contains("browser_apps"));
    try testing.expect(parser.process_groups.contains("native_apps"));

    // Check group contents
    const terminal_group = parser.process_groups.get("terminal_apps").?;
    try testing.expectEqual(@as(usize, 3), terminal_group.len);

    const browser_group = parser.process_groups.get("browser_apps").?;
    try testing.expectEqual(@as(usize, 3), browser_group.len);

    const native_group = parser.process_groups.get("native_apps").?;
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
    try testing.expect(parser.command_defs.contains("focus_west"));
    const cmd_def = parser.command_defs.get("focus_west").?;
    // Should have one text part
    try testing.expectEqual(@as(usize, 1), cmd_def.parts.len);
    try testing.expect(cmd_def.parts[0] == .text);
    try testing.expectEqualStrings("yabai -m window --focus west", cmd_def.parts[0].text);
    try testing.expectEqual(@as(u8, 0), cmd_def.max_placeholder);

    // Check hotkey has expanded command
    var it = mappings.hotkey_map.iterator();
    const entry = it.next().?;
    const hotkey = entry.key_ptr.*;

    if (hotkey.find_command_for_process("*")) |c| {
        try testing.expectEqualStrings("yabai -m window --focus west", c.command);
    } else {
        return error.TestExpectHotkeyCommandNotFound;
    }
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
    const cmd_def = parser.command_defs.get("yabai_focus").?;
    // Should have two parts: text and placeholder
    try testing.expectEqual(@as(usize, 2), cmd_def.parts.len);
    try testing.expect(cmd_def.parts[0] == .text);
    try testing.expectEqualStrings("yabai -m window --focus ", cmd_def.parts[0].text);
    try testing.expect(cmd_def.parts[1] == .placeholder);
    try testing.expectEqual(@as(u8, 1), cmd_def.parts[1].placeholder);
    try testing.expectEqual(@as(u8, 1), cmd_def.max_placeholder);

    // Find hotkeys and check their commands
    var hotkey_count: usize = 0;
    var it = mappings.hotkey_map.iterator();
    while (it.next()) |entry| {
        const hotkey = entry.key_ptr.*;
        // Since these hotkeys don't have process-specific mappings, they should have wildcard commands
        const cmd = hotkey.find_command_for_process("*");

        if (hotkey.key == 4) { // 'h' key
            try testing.expect(cmd != null);
            try testing.expectEqualStrings("yabai -m window --focus west", cmd.?.command);
            hotkey_count += 1;
        } else if (hotkey.key == 37) { // 'l' key
            try testing.expect(cmd != null);
            try testing.expectEqualStrings("yabai -m window --focus east", cmd.?.command);
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
    const cmd_def = parser.command_defs.get("window_action").?;
    try testing.expectEqual(@as(u8, 2), cmd_def.max_placeholder);

    // Check expanded command
    var it = mappings.hotkey_map.iterator();
    const entry = it.next().?;
    const hotkey = entry.key_ptr.*;
    const cmd = hotkey.find_command_for_process("*");
    try testing.expect(cmd != null);
    try testing.expectEqualStrings("yabai -m window --focus west", cmd.?.command);
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
    const cmd = hotkey.find_command_for_process("*");
    try testing.expect(cmd != null);
    try testing.expectEqualStrings("yabai -m window --toggle Music || open -a \"Music\"", cmd.?.command);
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

    // Test process-specific commands
    const terminal_cmd = hotkey.find_command_for_process("terminal");
    try testing.expect(terminal_cmd != null);
    try testing.expectEqualStrings("echo \"terminal app\"", terminal_cmd.?.command);

    // Test wildcard command
    const other_cmd = hotkey.find_command_for_process("some_other_app");
    try testing.expect(other_cmd != null);
    try testing.expectEqualStrings("echo \"other app\"", other_cmd.?.command);

    // Verify the process count (terminal + wildcard)
    try testing.expectEqual(@as(usize, 1), hotkey.getProcessCount()); // Only "terminal" is in mappings, wildcard is separate
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
    const cmd = hotkey.find_command_for_process("*");
    try testing.expect(cmd != null);
    try testing.expectEqualStrings("osascript -e 'display notification \"Hello \"World\"\" with title \"Test \"Message\"\"'", cmd.?.command);
}

test "Mode with command syntax" {
    const allocator = testing.allocator;
    var parser = try Parser.init(allocator);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    const config =
        \\:: window : echo "Window mode activated"
        \\:: browser : echo "Browser mode activated"
        \\:: default
        \\
        \\# Test basic mode activation with command (new syntax)
        \\cmd - w ; window : echo "Switching to window mode"
        \\
        \\# Test mode exit with command
        \\window < escape ; default : echo "Exiting window mode"
        \\
        \\# Test process-specific mode activation with command
        \\cmd - m [
        \\    "chrome"  ; browser : echo "Chrome entering browser mode"
        \\    "vscode"  ; window : echo "VSCode entering window mode"
        \\    *         ; default : echo "Other apps entering default mode"
        \\]
        \\
        \\# Test regular mode activation (original syntax for comparison)
        \\cmd - d ; default
    ;

    try parser.parse(&mappings, config);

    // Check that all modes were created
    try testing.expect(mappings.mode_map.contains("default"));
    try testing.expect(mappings.mode_map.contains("window"));
    try testing.expect(mappings.mode_map.contains("browser"));

    const default_mode = mappings.mode_map.get("default").?;
    const window_mode = mappings.mode_map.get("window").?;

    // Test 1: Basic mode activation with command (cmd - w ; window : echo "...")
    // Find the hotkey in default mode
    const ctx = Hotkey.KeyboardLookupContext{};
    const w_keypress = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = 0x0D }; // W key
    const w_hotkey = default_mode.hotkey_map.getKeyAdapted(w_keypress, ctx);
    try testing.expect(w_hotkey != null);

    // Check that it has the mode activation command
    const w_cmd = w_hotkey.?.find_command_for_process(";");
    try testing.expect(w_cmd != null);
    
    // Verify it's a mode_with_command variant
    switch (w_cmd.?) {
        .mode_with_command => |mode_cmd| {
            try testing.expectEqualStrings("window", mode_cmd.mode_name);
            try testing.expectEqualStrings("echo \"Switching to window mode\"", mode_cmd.command);
        },
        else => try testing.expect(false), // Should be mode_with_command
    }

    // Test 2: Mode exit with command (window < escape ; default : echo "...")
    const escape_keypress = Hotkey.KeyPress{ .flags = .{}, .key = 0x35 }; // Escape key
    const escape_hotkey = window_mode.hotkey_map.getKeyAdapted(escape_keypress, ctx);
    try testing.expect(escape_hotkey != null);

    const escape_cmd = escape_hotkey.?.find_command_for_process(";");
    try testing.expect(escape_cmd != null);
    
    switch (escape_cmd.?) {
        .mode_with_command => |mode_cmd| {
            try testing.expectEqualStrings("default", mode_cmd.mode_name);
            try testing.expectEqualStrings("echo \"Exiting window mode\"", mode_cmd.command);
        },
        else => try testing.expect(false),
    }

    // Test 3: Process-specific mode activation with command (cmd - m [...])
    const m_keypress = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = 0x2E }; // M key
    const m_hotkey = default_mode.hotkey_map.getKeyAdapted(m_keypress, ctx);
    try testing.expect(m_hotkey != null);

    // Test Chrome mapping
    const chrome_cmd = m_hotkey.?.find_command_for_process("chrome");
    try testing.expect(chrome_cmd != null);
    
    switch (chrome_cmd.?) {
        .mode_with_command => |mode_cmd| {
            try testing.expectEqualStrings("browser", mode_cmd.mode_name);
            try testing.expectEqualStrings("echo \"Chrome entering browser mode\"", mode_cmd.command);
        },
        else => try testing.expect(false),
    }

    // Test VSCode mapping
    const vscode_cmd = m_hotkey.?.find_command_for_process("vscode");
    try testing.expect(vscode_cmd != null);
    
    switch (vscode_cmd.?) {
        .mode_with_command => |mode_cmd| {
            try testing.expectEqualStrings("window", mode_cmd.mode_name);
            try testing.expectEqualStrings("echo \"VSCode entering window mode\"", mode_cmd.command);
        },
        else => try testing.expect(false),
    }

    // Test wildcard mapping
    const wildcard_cmd = m_hotkey.?.find_command_for_process("unknown_app");
    try testing.expect(wildcard_cmd != null);
    
    switch (wildcard_cmd.?) {
        .mode_with_command => |mode_cmd| {
            try testing.expectEqualStrings("default", mode_cmd.mode_name);
            try testing.expectEqualStrings("echo \"Other apps entering default mode\"", mode_cmd.command);
        },
        else => try testing.expect(false),
    }

    // Test 4: Regular mode activation (original syntax - cmd - d ; default)
    const d_keypress = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = 0x02 }; // D key
    const d_hotkey = default_mode.hotkey_map.getKeyAdapted(d_keypress, ctx);
    try testing.expect(d_hotkey != null);

    const d_cmd = d_hotkey.?.find_command_for_process(";");
    try testing.expect(d_cmd != null);
    
    // This should be a regular command (mode name only), not mode_with_command
    switch (d_cmd.?) {
        .command => |cmd| {
            try testing.expectEqualStrings("default", cmd);
        },
        else => try testing.expect(false), // Should be regular command
    }

    // Test 5: Verify memory management - check that ProcessCommand.deinit handles mode_with_command
    var test_cmd = Hotkey.ProcessCommand{ 
        .mode_with_command = .{
            .mode_name = try allocator.dupe(u8, "test_mode"),
            .command = try allocator.dupe(u8, "test_command"),
        }
    };
    
    // This should not leak memory
    test_cmd.deinit(allocator);
}

test "Mode entry commands with mode+command syntax" {
    const allocator = testing.allocator;
    var parser = try Parser.init(allocator);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    const config =
        \\:: window : echo "Window mode entry command"
        \\:: browser : echo "Browser mode entry command"
        \\:: default
        \\
        \\# Regular mode activation (should execute mode entry command)
        \\cmd - 1 ; window
        \\
        \\# Mode activation with command (should execute BOTH mode entry AND hotkey command)
        \\cmd - 2 ; window : echo "Hotkey command"
        \\
        \\# Mode activation with command to different mode
        \\cmd - 3 ; browser : echo "Browser hotkey command"
    ;

    try parser.parse(&mappings, config);

    // Verify modes were created with entry commands
    const window_mode = mappings.mode_map.get("window").?;
    const browser_mode = mappings.mode_map.get("browser").?;
    const default_mode = mappings.mode_map.get("default").?;

    try testing.expectEqualStrings("echo \"Window mode entry command\"", window_mode.command.?);
    try testing.expectEqualStrings("echo \"Browser mode entry command\"", browser_mode.command.?);
    try testing.expect(default_mode.command == null); // Default mode has no entry command

    // Test 1: Regular mode activation (cmd - 1 ; window)
    const ctx = Hotkey.KeyboardLookupContext{};
    const key1_press = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = 0x12 }; // 1 key
    const hotkey1 = default_mode.hotkey_map.getKeyAdapted(key1_press, ctx);
    try testing.expect(hotkey1 != null);

    const cmd1 = hotkey1.?.find_command_for_process(";");
    try testing.expect(cmd1 != null);
    
    // Should be regular command (mode name only)
    switch (cmd1.?) {
        .command => |mode_name| {
            try testing.expectEqualStrings("window", mode_name);
        },
        else => try testing.expect(false),
    }

    // Test 2: Mode activation with command (cmd - 2 ; window : echo "Hotkey command")
    const key2_press = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = 0x13 }; // 2 key
    const hotkey2 = default_mode.hotkey_map.getKeyAdapted(key2_press, ctx);
    try testing.expect(hotkey2 != null);

    const cmd2 = hotkey2.?.find_command_for_process(";");
    try testing.expect(cmd2 != null);
    
    // Should be mode_with_command variant
    switch (cmd2.?) {
        .mode_with_command => |mode_cmd| {
            try testing.expectEqualStrings("window", mode_cmd.mode_name);
            try testing.expectEqualStrings("echo \"Hotkey command\"", mode_cmd.command);
        },
        else => try testing.expect(false),
    }

    // Test 3: Mode activation with command to different mode (cmd - 3 ; browser : echo "Browser hotkey command")
    const key3_press = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = 0x14 }; // 3 key
    const hotkey3 = default_mode.hotkey_map.getKeyAdapted(key3_press, ctx);
    try testing.expect(hotkey3 != null);

    const cmd3 = hotkey3.?.find_command_for_process(";");
    try testing.expect(cmd3 != null);
    
    // Should be mode_with_command variant for browser
    switch (cmd3.?) {
        .mode_with_command => |mode_cmd| {
            try testing.expectEqualStrings("browser", mode_cmd.mode_name);
            try testing.expectEqualStrings("echo \"Browser hotkey command\"", mode_cmd.command);
        },
        else => try testing.expect(false),
    }

    // Note: The actual execution of mode entry commands is tested through integration
    // tests since it requires the full skhd runtime. This test verifies that the
    // data structures are set up correctly to support mode entry command execution.
}
