const std = @import("std");
const Sequence = @import("Sequence.zig");

comptime {
    _ = Sequence;
}
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
    var hotkey1 = try Hotkey.create(allocator, &.{.{ .flags = ModifierFlag{ .cmd = true }, .key = 0x31 }}); // '1' key
    defer hotkey1.destroy();

    var hotkey2 = try Hotkey.create(allocator, &.{.{ .flags = ModifierFlag{ .cmd = true }, .key = 0x31 }}); // '1' key
    defer hotkey2.destroy();

    // Test equality
    try testing.expect(Hotkey.eql(hotkey1, hotkey2));

    // A different key means inequality
    var hotkey3 = try Hotkey.create(allocator, &.{.{ .flags = ModifierFlag{ .cmd = true }, .key = 0x32 }}); // '2' key
    defer hotkey3.destroy();
    try testing.expect(!Hotkey.eql(hotkey1, hotkey3));
}

test "Hotkey left/right modifier comparison" {
    const allocator = testing.allocator;

    // Test that general modifier matches specific modifiers
    var general_cmd = try Hotkey.create(allocator, &.{.{ .flags = ModifierFlag{ .cmd = true }, .key = 0x31 }});
    defer general_cmd.destroy();

    var left_cmd = try Hotkey.create(allocator, &.{.{ .flags = ModifierFlag{ .lcmd = true }, .key = 0x31 }});
    defer left_cmd.destroy();

    var right_cmd = try Hotkey.create(allocator, &.{.{ .flags = ModifierFlag{ .rcmd = true }, .key = 0x31 }});
    defer right_cmd.destroy();

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

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
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

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
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

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
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

    // Check if the hotkey has activation for wildcard process
    var hotkey_iter = default_mode.?.hotkey_map.iterator();
    if (hotkey_iter.next()) |entry| {
        const hotkey = entry.key_ptr.*;
        const process_cmd = hotkey.find_command_for_process("*");
        try testing.expect(process_cmd != null);
        try testing.expect(process_cmd.? == .activation);
    }
}

test "Left/right modifier parsing" {
    const allocator = testing.allocator;

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
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
        if (hotkey.chords[0].flags.lcmd and !hotkey.chords[0].flags.rcmd and !hotkey.chords[0].flags.cmd) {
            found_lcmd = true;
        }
        if (hotkey.chords[0].flags.rcmd and !hotkey.chords[0].flags.lcmd and !hotkey.chords[0].flags.cmd) {
            found_rcmd = true;
        }
        if (hotkey.chords[0].flags.lalt and hotkey.chords[0].flags.rshift) {
            found_mixed = true;
        }
    }

    try testing.expect(found_lcmd);
    try testing.expect(found_rcmd);
    try testing.expect(found_mixed);
}

test "Blacklist parsing" {
    const allocator = testing.allocator;

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
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

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    // Default shell should be from environment or /bin/bash
    const initial_shell = mappings.shell;
    try testing.expect(initial_shell.len > 0);

    var parser = try Parser.init(allocator, std.testing.io);
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
    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    // Should use SHELL env var if set, otherwise /bin/bash
    if (@import("utils.zig").getenv("SHELL")) |env_shell| {
        try testing.expectEqualStrings(env_shell, mappings.shell);
    } else {
        try testing.expectEqualStrings("/bin/bash", mappings.shell);
    }
}

test "Config file resolution" {
    const allocator = testing.allocator;
    const io = std.testing.io;

    // Test getting config file
    const getConfigFile = @import("utils.zig").getConfigFile;

    // This should resolve to a path based on environment
    const config_path = try getConfigFile(allocator, io, "skhdrc");
    defer allocator.free(config_path);

    // Should be one of:
    // - $XDG_CONFIG_HOME/skhd/skhdrc
    // - $HOME/.config/skhd/skhdrc
    // - $HOME/.skhdrc
    // - skhdrc (in current dir)
    try testing.expect(config_path.len > 0);

    // Test that the function returns a valid path
    if (@import("utils.zig").getenv("HOME")) |home| {
        // If we have HOME, the path should contain it or be the fallback
        const has_home = std.mem.indexOf(u8, config_path, home) != null;
        const is_fallback = std.mem.eql(u8, config_path, "skhdrc");
        try testing.expect(has_home or is_fallback);
    }
}

test "Config reload memory leak test" {
    const allocator = testing.allocator;

    // Create temporary config files
    const test_id = std.testing.random_seed;
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

        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = config_path, .data = initial_config });
    }

    // Clean up config file after test
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, config_path) catch {};

    // Initialize skhd with initial config
    var skhd = try Skhd.init(allocator, std.testing.io, config_path, false, false);
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

        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = config_path, .data = modified_config });
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

        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = config_path, .data = multi_config });

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
    const test_id = std.testing.random_seed;
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

        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = config_path, .data = config });
    }

    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, config_path) catch {};

    // Initialize skhd
    var skhd = try Skhd.init(allocator, std.testing.io, config_path, false, false);
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

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    // Test missing '<' after mode
    parser.clearError();
    const err1 = parser.parse(&mappings, "mymode cmd - a : echo test");
    try testing.expectError(error.ParseErrorOccurred, err1);
    try testing.expect(parser.error_info != null);
    const parse_err1 = parser.error_info.?;
    try testing.expect(std.mem.containsAtLeast(u8, parse_err1.message, 1, "Mode 'mymode' not found"));
    try testing.expect(parse_err1.line == 1);

    // Create the mode first, then test missing '<'
    try mappings.put_mode(try Mode.init(allocator, "mymode"));
    parser.clearError();
    const err1b = parser.parse(&mappings, "mymode cmd - a : echo test");
    try testing.expectError(error.ParseErrorOccurred, err1b);
    const parse_err1b = parser.error_info.?;
    try testing.expectEqualStrings("Expected '<' after mode identifier", parse_err1b.message);

    // Test unknown mode
    parser.clearError();
    const err2 = parser.parse(&mappings, "foo - b : echo test");
    try testing.expectError(error.ParseErrorOccurred, err2);
    try testing.expect(parser.error_info != null);
    const parse_err2 = parser.error_info.?;
    try testing.expect(std.mem.containsAtLeast(u8, parse_err2.message, 1, "Mode 'foo' not found"));

    // Test missing '-' after modifier
    parser.clearError();
    const err3 = parser.parse(&mappings, "cmd b : echo test");
    try testing.expectError(error.ParseErrorOccurred, err3);
    try testing.expect(parser.error_info != null);
    const parse_err3 = parser.error_info.?;
    try testing.expectEqualStrings("Expected '-' after modifier", parse_err3.message);

    // Test unknown key
    parser.clearError();
    const err4 = parser.parse(&mappings, "cmd - unknown_key : echo test");
    try testing.expectError(error.ParseErrorOccurred, err4);
    try testing.expect(parser.error_info != null);
    const parse_err4 = parser.error_info.?;
    try testing.expectEqualStrings("Expected key, key hex, or literal", parse_err4.message);

    // Test empty process list
    parser.clearError();
    const err5 = parser.parse(&mappings, "cmd - d []");
    try testing.expectError(error.ParseErrorOccurred, err5);
    try testing.expect(parser.error_info != null);
    const parse_err5 = parser.error_info.?;
    try testing.expectEqualStrings("Empty process list", parse_err5.message);

    // Test duplicate mode declaration
    parser.clearError();
    const err6 = parser.parse(&mappings, ":: test_mode\n:: test_mode");
    try testing.expectError(error.ParseErrorOccurred, err6);
    try testing.expect(parser.error_info != null);
    const parse_err6 = parser.error_info.?;
    try testing.expect(std.mem.containsAtLeast(u8, parse_err6.message, 1, "Mode 'test_mode' already exists"));
    try testing.expect(parse_err6.line == 2);

    // Test unknown option
    parser.clearError();
    const err7 = parser.parse(&mappings, ".unknown_option");
    try testing.expectError(error.ParseErrorOccurred, err7);
    try testing.expect(parser.error_info != null);
    const parse_err7 = parser.error_info.?;
    try testing.expect(std.mem.containsAtLeast(u8, parse_err7.message, 1, "Unknown option 'unknown_option'"));
}

test "Parser error message formatting" {

    // Test error formatting without file path
    var err1 = try ParseError.fromPosition(testing.allocator, 5, 10, "Test error message", null);
    defer err1.deinit();
    var buf: [256]u8 = undefined;
    const result1 = try std.fmt.bufPrint(&buf, "{f}", .{err1});
    try testing.expectEqualStrings("5:10: error: Test error message", result1);

    // Test error formatting with file path
    var err2 = try ParseError.fromPosition(testing.allocator, 3, 7, "Another error", "test.skhdrc");
    defer err2.deinit();
    const result2 = try std.fmt.bufPrint(&buf, "{f}", .{err2});
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
    const result3 = try std.fmt.bufPrint(&buf, "{f}", .{err3});
    try testing.expectEqualStrings("config.skhdrc:2:15: error: Unknown key near 'badkey'", result3);
}

test "Parser error with multiline input" {
    const allocator = testing.allocator;

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
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

    const parse_err = parser.error_info.?;
    try testing.expect(std.mem.containsAtLeast(u8, parse_err.message, 1, "Mode 'bad' not found"));
    try testing.expect(parse_err.line == 3);
    try testing.expectEqualStrings("bad", parse_err.token_text.?);
}

test "Hot reload enable/disable" {
    const allocator = testing.allocator;

    // Create temporary config file
    const test_id = std.testing.random_seed;
    const config_path = try std.fmt.allocPrint(allocator, "/tmp/skhd_test_hotload_{d}.skhdrc", .{test_id});
    defer allocator.free(config_path);

    // Write initial config
    {
        const config = "cmd - a : echo \"test A\"";
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = config_path, .data = config });
    }

    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, config_path) catch {};

    // Initialize skhd
    var skhd = try Skhd.init(allocator, std.testing.io, config_path, false, false);
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
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = config_path, .data = config });
    }
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, config_path) catch {};

    var skhd = try Skhd.init(allocator, std.testing.io, config_path, false, false);
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
        try testing.expect(found.?.chords[0].flags.alt);
        try testing.expect(!found.?.chords[0].flags.lalt);
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
        try testing.expect(found.?.chords[0].flags.cmd);
        try testing.expect(found.?.chords[0].flags.shift);
    }
}

test "keyboard lalt should match config alt" {
    const allocator = std.testing.allocator;

    // Create test config with just "alt - a"
    const config_path = "/tmp/skhd_test_lalt_matches_alt.txt";
    {
        const config = "alt - a : echo \"alt - a pressed\"";
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = config_path, .data = config });
    }
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, config_path) catch {};

    var skhd = try Skhd.init(allocator, std.testing.io, config_path, false, false);
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
                std.debug.print("  config hotkey: flags={any}, key={d}\n", .{ hotkey.chords[0].flags, hotkey.chords[0].key });
            }
        }
        try testing.expect(found != null);
        try testing.expect(found.?.chords[0].flags.alt);
        try testing.expect(!found.?.chords[0].flags.lalt);
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
        try testing.expect(found.?.chords[0].flags.alt);
        try testing.expect(!found.?.chords[0].flags.ralt);
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
        try testing.expect(found.?.chords[0].flags.alt);
    }
}

test "find_command_for_process function with process matching" {
    const allocator = std.testing.allocator;

    // Create a hotkey with some process names
    var hotkey = try Hotkey.create(allocator, &.{.{ .flags = .{}, .key = 0 }});
    defer hotkey.destroy();

    try hotkey.add_process_command("chrome", "echo chrome");
    try hotkey.add_process_command("firefox", "echo firefox");
    try hotkey.add_process_command("whatsapp", "echo whatsapp");
    try hotkey.add_process_command("*", "echo wildcard");

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
    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
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

    // Check that hotkeys were created
    const default_mode = mappings.mode_map.get("default").?;
    try testing.expectEqual(@as(usize, 3), default_mode.hotkey_map.count());

    // Verify that terminal apps are properly set as unbound
    var it = default_mode.hotkey_map.iterator();
    while (it.next()) |entry| {
        const hotkey = entry.key_ptr.*;

        // Check if terminal apps have unbound action
        if (hotkey.find_command_for_process("kitty")) |cmd| {
            if (hotkey.chords[0].key == 0x33 or hotkey.chords[0].key == 0x7B) { // backspace or left
                try testing.expect(cmd == .unbound);
            }
        }

        // Check if chrome has unbound action for home key
        if (hotkey.chords[0].key == 0x73) { // home
            if (hotkey.find_command_for_process("chrome")) |cmd| {
                try testing.expect(cmd == .unbound);
            }
        }
    }
}

test "Command definitions - single placeholder" {
    const allocator = testing.allocator;
    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
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
    var it = mappings.mode_map.get("default").?.hotkey_map.iterator();
    while (it.next()) |entry| {
        const hotkey = entry.key_ptr.*;
        // Since these hotkeys don't have process-specific mappings, they should have wildcard commands
        const cmd = hotkey.find_command_for_process("*");

        if (hotkey.chords[0].key == 4) { // 'h' key
            try testing.expect(cmd != null);
            try testing.expectEqualStrings("yabai -m window --focus west", cmd.?.command);
            hotkey_count += 1;
        } else if (hotkey.chords[0].key == 37) { // 'l' key
            try testing.expect(cmd != null);
            try testing.expectEqualStrings("yabai -m window --focus east", cmd.?.command);
            hotkey_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), hotkey_count);
}

test "Command definitions - multiple placeholders" {
    const allocator = testing.allocator;
    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
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
    var it = mappings.mode_map.get("default").?.hotkey_map.iterator();
    const entry = it.next().?;
    const hotkey = entry.key_ptr.*;
    const cmd = hotkey.find_command_for_process("*");
    try testing.expect(cmd != null);
    try testing.expectEqualStrings("yabai -m window --focus west", cmd.?.command);
}

test "Command definitions - repeated placeholder" {
    const allocator = testing.allocator;
    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    const config =
        \\.define toggle_app : yabai -m window --toggle {{1}} || open -a "{{1}}"
        \\cmd - m : @toggle_app("Music")
    ;

    try parser.parse(&mappings, config);

    // Check expanded command
    var it = mappings.mode_map.get("default").?.hotkey_map.iterator();
    const entry = it.next().?;
    const hotkey = entry.key_ptr.*;
    const cmd = hotkey.find_command_for_process("*");
    try testing.expect(cmd != null);
    try testing.expectEqualStrings("yabai -m window --toggle Music || open -a \"Music\"", cmd.?.command);
}

test "Command definitions - in process list" {
    const allocator = testing.allocator;
    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
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
    var it = mappings.mode_map.get("default").?.hotkey_map.iterator();
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
    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
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
    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    const config =
        \\.define notify : osascript -e 'display notification "{{1}}" with title "{{2}}"'
        \\cmd - n : @notify("Hello \"World\"", "Test \"Message\"")
    ;

    try parser.parse(&mappings, config);

    // Check expanded command has properly escaped quotes
    var it = mappings.mode_map.get("default").?.hotkey_map.iterator();
    const entry = it.next().?;
    const hotkey = entry.key_ptr.*;
    const cmd = hotkey.find_command_for_process("*");
    try testing.expect(cmd != null);
    try testing.expectEqualStrings("osascript -e 'display notification \"Hello \"World\"\" with title \"Test \"Message\"\"'", cmd.?.command);
}

test "Duplicate hotkey detection - same mode same hotkey" {
    const allocator = std.testing.allocator;

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    // Define the same hotkey twice in default mode
    const config =
        \\cmd - a : echo "first"
        \\cmd - a : echo "second"
    ;

    // This should report an error
    const result = parser.parse(&mappings, config);
    try testing.expectError(error.ParseErrorOccurred, result);

    // Check error message
    const error_info = parser.error_info.?;
    try testing.expect(std.mem.containsAtLeast(u8, error_info.message, 1, "Duplicate hotkey"));
    try testing.expect(std.mem.containsAtLeast(u8, error_info.message, 1, "cmd - a"));
    try testing.expect(error_info.line == 2);
}

test "Duplicate hotkey detection - specific modifiers" {
    const allocator = std.testing.allocator;

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    // Test exact duplicates with specific modifiers
    const config =
        \\lcmd - a : echo "first"
        \\lcmd - a : echo "second"
    ;

    const result = parser.parse(&mappings, config);
    try testing.expectError(error.ParseErrorOccurred, result);

    const error_info = parser.error_info.?;
    try testing.expect(std.mem.containsAtLeast(u8, error_info.message, 1, "Duplicate hotkey"));
    try testing.expect(std.mem.containsAtLeast(u8, error_info.message, 1, "lcmd - a"));
}

test "Duplicate hotkey detection - different modes allowed" {
    const allocator = std.testing.allocator;

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    // Same hotkey in different modes should be allowed
    const config =
        \\:: test_mode
        \\cmd - a : echo "default"
        \\test_mode < cmd - a : echo "test mode"
    ;

    // This should parse successfully
    try parser.parse(&mappings, config);

    // Verify both hotkeys exist
    const default_mode = mappings.mode_map.get("default").?;
    const test_mode = mappings.mode_map.get("test_mode").?;
    try testing.expectEqual(@as(usize, 1), default_mode.hotkey_map.count());
    try testing.expectEqual(@as(usize, 1), test_mode.hotkey_map.count());
}

test "Duplicate hotkey detection - left/right modifiers are different" {
    const allocator = std.testing.allocator;

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    // Different left/right modifiers should be allowed (not duplicates)
    const config =
        \\lcmd - a : echo "left cmd"
        \\rcmd - a : echo "right cmd"
    ;

    try parser.parse(&mappings, config);

    const default_mode = mappings.mode_map.get("default").?;
    try testing.expectEqual(@as(usize, 2), default_mode.hotkey_map.count());
}

test "Duplicate hotkey detection - general modifier conflicts with specific modifiers" {
    const allocator = std.testing.allocator;

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    const config =
        \\cmd - a : echo "general cmd"
        \\lcmd - a : echo "left cmd"
    ;

    const result = parser.parse(&mappings, config);
    try testing.expectError(error.ParseErrorOccurred, result);
    try testing.expect(std.mem.containsAtLeast(u8, parser.error_info.?.message, 1, "Duplicate hotkey"));
}

test "Duplicate hotkey detection - specific modifier conflicts with later general modifier" {
    const allocator = std.testing.allocator;

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    const config =
        \\lcmd - a : echo "left cmd"
        \\cmd - a : echo "general cmd"
    ;

    const result = parser.parse(&mappings, config);
    try testing.expectError(error.ParseErrorOccurred, result);
    try testing.expect(std.mem.containsAtLeast(u8, parser.error_info.?.message, 1, "Duplicate hotkey"));
}

test "Duplicate hotkey detection - multi mode assignment" {
    const allocator = std.testing.allocator;

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    // Test duplicate detection with multi-mode hotkey
    const config =
        \\:: mode1
        \\:: mode2
        \\mode1, mode2 < cmd - a : echo "multi mode"
        \\mode1 < cmd - a : echo "duplicate in mode1"
    ;

    const result = parser.parse(&mappings, config);
    try testing.expectError(error.ParseErrorOccurred, result);

    const error_info = parser.error_info.?;
    try testing.expect(std.mem.containsAtLeast(u8, error_info.message, 1, "Duplicate hotkey"));
    try testing.expect(std.mem.containsAtLeast(u8, error_info.message, 1, "mode1"));
    try testing.expect(error_info.line == 4);
}

test "Unbound action - simple syntax" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    const config =
        \\cmd - a ~
        \\cmd - b : echo "normal command"
    ;

    try parser.parse(&mappings, config);

    // Check that unbound hotkey was created
    const default_mode = mappings.mode_map.get("default").?;
    try testing.expectEqual(@as(usize, 2), default_mode.hotkey_map.count());

    // Find the unbound hotkey
    var it = default_mode.hotkey_map.iterator();
    var found_unbound = false;
    while (it.next()) |entry| {
        const hotkey = entry.key_ptr.*;
        if (hotkey.chords[0].key == 0x00) { // a key
            found_unbound = true;
            // Check it has unbound command
            if (hotkey.find_command_for_process("*")) |cmd| {
                try testing.expect(cmd == .unbound);
            } else {
                return error.TestExpectUnboundCommand;
            }
        }
    }
    try testing.expect(found_unbound);
}

test "Unbound action - with modes" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    const config =
        \\:: test_mode
        \\test_mode < cmd - x ~
        \\test_mode < cmd - y : echo "in test mode"
        \\cmd - z ~
    ;

    try parser.parse(&mappings, config);

    // Check test_mode has unbound hotkey
    const test_mode = mappings.mode_map.get("test_mode").?;
    var found_mode_unbound = false;
    var it = test_mode.hotkey_map.iterator();
    while (it.next()) |entry| {
        const hotkey = entry.key_ptr.*;
        if (hotkey.chords[0].key == 0x07) { // x key
            found_mode_unbound = true;
            if (hotkey.find_command_for_process("*")) |cmd| {
                try testing.expect(cmd == .unbound);
            }
        }
    }
    try testing.expect(found_mode_unbound);

    // Check default mode has unbound hotkey
    const default_mode = mappings.mode_map.get("default").?;
    var found_default_unbound = false;
    it = default_mode.hotkey_map.iterator();
    while (it.next()) |entry| {
        const hotkey = entry.key_ptr.*;
        if (hotkey.chords[0].key == 0x06) { // z key
            found_default_unbound = true;
            if (hotkey.find_command_for_process("*")) |cmd| {
                try testing.expect(cmd == .unbound);
            }
        }
    }
    try testing.expect(found_default_unbound);
}

test "Unbound action - with passthrough" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    const config =
        \\cmd - a -> ~
    ;

    try parser.parse(&mappings, config);

    // Check that hotkey has both passthrough flag and unbound command
    const default_mode = mappings.mode_map.get("default").?;
    var it = default_mode.hotkey_map.iterator();
    const entry = it.next().?;
    const hotkey = entry.key_ptr.*;

    try testing.expect(hotkey.passthrough);
    if (hotkey.find_command_for_process("*")) |cmd| {
        try testing.expect(cmd == .unbound);
    }
}

test "Unbound action - mixed with process lists" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    const config =
        \\cmd - space ~  # Simple unbound
        \\cmd - tab [     # Process list with unbound
        \\    "terminal" ~
        \\    "firefox" : echo "firefox tab"
        \\    * | ctrl - tab
        \\]
    ;

    try parser.parse(&mappings, config);

    const default_mode = mappings.mode_map.get("default").?;
    try testing.expectEqual(@as(usize, 2), default_mode.hotkey_map.count());

    // Check cmd-space is fully unbound
    var it = default_mode.hotkey_map.iterator();
    while (it.next()) |entry| {
        const hotkey = entry.key_ptr.*;
        if (hotkey.chords[0].key == 0x31) { // space key
            if (hotkey.find_command_for_process("*")) |cmd| {
                try testing.expect(cmd == .unbound);
            }
        } else if (hotkey.chords[0].key == 0x30) { // tab key
            // Check terminal is unbound
            if (hotkey.find_command_for_process("terminal")) |cmd| {
                try testing.expect(cmd == .unbound);
            }
            // Check firefox has command
            if (hotkey.find_command_for_process("firefox")) |cmd| {
                try testing.expect(cmd == .command);
                try testing.expectEqualStrings("echo \"firefox tab\"", cmd.command);
            }
            // Check others forward
            if (hotkey.find_command_for_process("other")) |cmd| {
                try testing.expect(cmd == .forwarded);
            }
        }
    }
}

test "mode activation uses activation variant" {
    const allocator = std.testing.allocator;

    const config =
        \\:: window
        \\cmd - w ; window
    ;

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    try parser.parseWithPath(&mappings, config, "test.conf");

    // Get the default mode and find the hotkey
    const default_mode = mappings.mode_map.getPtr("default").?;
    var it = default_mode.hotkey_map.iterator();

    var found_activation = false;
    while (it.next()) |entry| {
        const hotkey = entry.key_ptr.*;
        if (hotkey.chords[0].key == 0x0D and hotkey.chords[0].flags.cmd) { // cmd - w
            const process_cmd = hotkey.find_command_for_process("*");
            try std.testing.expect(process_cmd != null);
            switch (process_cmd.?) {
                .activation => |act| {
                    try std.testing.expectEqualStrings("window", act.mode_name);
                    try std.testing.expect(act.command == null);
                    found_activation = true;
                },
                else => return error.WrongCommandType,
            }
        }
    }

    try std.testing.expect(found_activation);
}

test "mode activation with command" {
    const allocator = std.testing.allocator;

    const config =
        \\:: window
        \\cmd - w ; window : echo "Entering window mode"
        \\escape ; default : echo "Back to default"
    ;

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    try parser.parseWithPath(&mappings, config, "test.conf");

    // Get the default mode and find the hotkey
    const default_mode = mappings.mode_map.getPtr("default").?;
    var it = default_mode.hotkey_map.iterator();

    var found_window_activation = false;
    var found_default_activation = false;

    while (it.next()) |entry| {
        const hotkey = entry.key_ptr.*;
        if (hotkey.chords[0].key == 0x0D and hotkey.chords[0].flags.cmd) { // cmd - w
            const process_cmd = hotkey.find_command_for_process("*");
            try std.testing.expect(process_cmd != null);
            switch (process_cmd.?) {
                .activation => |act| {
                    try std.testing.expectEqualStrings("window", act.mode_name);
                    try std.testing.expect(act.command != null);
                    try std.testing.expectEqualStrings("echo \"Entering window mode\"", act.command.?);
                    found_window_activation = true;
                },
                else => return error.WrongCommandType,
            }
        } else if (hotkey.chords[0].key == 0x35) { // escape
            const process_cmd = hotkey.find_command_for_process("*");
            try std.testing.expect(process_cmd != null);
            switch (process_cmd.?) {
                .activation => |act| {
                    try std.testing.expectEqualStrings("default", act.mode_name);
                    try std.testing.expect(act.command != null);
                    try std.testing.expectEqualStrings("echo \"Back to default\"", act.command.?);
                    found_default_activation = true;
                },
                else => return error.WrongCommandType,
            }
        }
    }

    try std.testing.expect(found_window_activation);
    try std.testing.expect(found_default_activation);
}

test "mode activation with command reference" {
    const allocator = std.testing.allocator;

    const config =
        \\.define notify : osascript -e 'display notification "{{1}}" with title "skhd"'
        \\:: window
        \\cmd - w ; window : @notify("Window mode active")
    ;

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    try parser.parseWithPath(&mappings, config, "test.conf");

    // Get the default mode and find the hotkey
    const default_mode = mappings.mode_map.getPtr("default").?;
    var it = default_mode.hotkey_map.iterator();

    var found_activation = false;
    while (it.next()) |entry| {
        const hotkey = entry.key_ptr.*;
        if (hotkey.chords[0].key == 0x0D and hotkey.chords[0].flags.cmd) { // cmd - w
            const process_cmd = hotkey.find_command_for_process("*");
            try std.testing.expect(process_cmd != null);
            switch (process_cmd.?) {
                .activation => |act| {
                    try std.testing.expectEqualStrings("window", act.mode_name);
                    try std.testing.expect(act.command != null);
                    try std.testing.expectEqualStrings("osascript -e 'display notification \"Window mode active\" with title \"skhd\"'", act.command.?);
                    found_activation = true;
                },
                else => return error.WrongCommandType,
            }
        }
    }

    try std.testing.expect(found_activation);
}

test "mode activation in process list" {
    const allocator = std.testing.allocator;

    const config =
        \\:: vim_mode
        \\:: browser_mode
        \\cmd - m [
        \\    "terminal" ; vim_mode : echo "Vim mode for terminal"
        \\    "chrome" ; browser_mode
        \\    * ; default : echo "Back to default"
        \\]
    ;

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    try parser.parseWithPath(&mappings, config, "test.conf");

    // Get the default mode and find the hotkey
    const default_mode = mappings.mode_map.getPtr("default").?;
    var it = default_mode.hotkey_map.iterator();

    var hotkey: ?*Hotkey = null;
    while (it.next()) |entry| {
        const hk = entry.key_ptr.*;
        if (hk.chords[0].key == 0x2E) { // m key
            hotkey = hk;
            break;
        }
    }

    try std.testing.expect(hotkey != null);

    // Check terminal process has vim_mode activation with command
    const terminal_cmd = hotkey.?.find_command_for_process("terminal");
    try std.testing.expect(terminal_cmd != null);
    switch (terminal_cmd.?) {
        .activation => |act| {
            try std.testing.expectEqualStrings("vim_mode", act.mode_name);
            try std.testing.expect(act.command != null);
            try std.testing.expectEqualStrings("echo \"Vim mode for terminal\"", act.command.?);
        },
        else => return error.WrongCommandType,
    }

    // Check chrome process has browser_mode activation without command
    const chrome_cmd = hotkey.?.find_command_for_process("chrome");
    try std.testing.expect(chrome_cmd != null);
    switch (chrome_cmd.?) {
        .activation => |act| {
            try std.testing.expectEqualStrings("browser_mode", act.mode_name);
            try std.testing.expect(act.command == null);
        },
        else => return error.WrongCommandType,
    }

    // Check wildcard has default mode activation with command
    const wildcard_cmd = hotkey.?.find_command_for_process("*");
    try std.testing.expect(wildcard_cmd != null);
    switch (wildcard_cmd.?) {
        .activation => |act| {
            try std.testing.expectEqualStrings("default", act.mode_name);
            try std.testing.expect(act.command != null);
            try std.testing.expectEqualStrings("echo \"Back to default\"", act.command.?);
        },
        else => return error.WrongCommandType,
    }
}

test "process group command reference parsing" {
    const allocator = std.testing.allocator;

    // Test specifically: process groups with command references vs regular commands containing @
    const config =
        \\.define browsers ["firefox", "chrome"]
        \\.define echo_cmd : echo "{{1}}"
        \\
        \\# Process group with command reference (empty token + reference)
        \\cmd - a [
        \\    @browsers : @echo_cmd("hello")
        \\]
        \\
        \\# Process group with regular command containing @
        \\cmd - b [
        \\    @browsers : echo @not_a_reference
        \\]
        \\
        \\# Mix of both in same list
        \\cmd - c [
        \\    "terminal" : @echo_cmd("term")
        \\    @browsers : echo @symbol
        \\    * : @echo_cmd("wildcard")
        \\]
    ;

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    try parser.parseWithPath(&mappings, config, "test.conf");

    const default_mode = mappings.mode_map.getPtr("default").?;

    // Find cmd-a and verify browsers have expanded command
    var it = default_mode.hotkey_map.iterator();
    while (it.next()) |entry| {
        const hk = entry.key_ptr.*;
        if (hk.chords[0].key == 0x00 and hk.chords[0].flags.cmd) { // A key
            // Check firefox mapping
            const firefox_cmd = hk.find_command_for_process("firefox").?.command;
            try std.testing.expectEqualStrings("echo \"hello\"", firefox_cmd);
            // Check chrome mapping
            const chrome_cmd = hk.find_command_for_process("chrome").?.command;
            try std.testing.expectEqualStrings("echo \"hello\"", chrome_cmd);
        } else if (hk.chords[0].key == 0x0B and hk.chords[0].flags.cmd) { // B key
            // Check that @ symbol is preserved in regular command
            const firefox_cmd = hk.find_command_for_process("firefox").?.command;
            try std.testing.expectEqualStrings("echo @not_a_reference", firefox_cmd);
        }
    }
}

test "empty command token with reference" {
    const allocator = std.testing.allocator;

    // Test the specific case: ": @ref" should parse as command reference
    // But ": echo @ref" should parse as literal command
    const config =
        \\.define test_cmd : echo "test {{1}}"
        \\# Empty command token followed by reference
        \\cmd - a : @test_cmd("hello")
        \\# Non-empty command token with @ symbol  
        \\cmd - b : echo @not_a_reference
    ;

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    try parser.parseWithPath(&mappings, config, "test.conf");

    const default_mode = mappings.mode_map.getPtr("default").?;

    // Find both hotkeys
    var cmd_a: ?[:0]const u8 = null;
    var cmd_b: ?[:0]const u8 = null;

    var it = default_mode.hotkey_map.iterator();
    while (it.next()) |entry| {
        const hk = entry.key_ptr.*;
        if (hk.chords[0].key == 0x00 and hk.chords[0].flags.cmd) { // A key
            cmd_a = hk.wildcard_command.?.command;
        } else if (hk.chords[0].key == 0x0B and hk.chords[0].flags.cmd) { // B key
            cmd_b = hk.wildcard_command.?.command;
        }
    }

    // cmd-a should have expanded command reference
    try std.testing.expect(cmd_a != null);
    try std.testing.expectEqualStrings("echo \"test hello\"", cmd_a.?);

    // cmd-b should have literal command with @
    try std.testing.expect(cmd_b != null);
    try std.testing.expectEqualStrings("echo @not_a_reference", cmd_b.?);
}

test "mode declaration command references" {
    const allocator = std.testing.allocator;

    // Test mode declarations with command references vs regular commands
    const config =
        \\.define mode_cmd : echo "entering {{1}}"
        \\
        \\# Mode with command reference
        \\:: mode1 : @mode_cmd("mode1")
        \\
        \\# Mode with regular command containing @
        \\:: mode2 : echo @not_a_reference
    ;

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    try parser.parseWithPath(&mappings, config, "test.conf");

    // Verify mode1 has expanded command
    const mode1 = mappings.mode_map.getPtr("mode1").?;
    try std.testing.expect(mode1.command != null);
    try std.testing.expectEqualStrings("echo \"entering mode1\"", mode1.command.?);

    // Verify mode2 has literal command with @
    const mode2 = mappings.mode_map.getPtr("mode2").?;
    try std.testing.expect(mode2.command != null);
    try std.testing.expectEqualStrings("echo @not_a_reference", mode2.command.?);
}

test "empty command followed by process group" {
    const allocator = std.testing.allocator;

    // Test case: empty command token followed by process group on next line
    const config =
        \\.define browsers ["firefox", "chrome"]
        \\cmd - a [
        \\    "firefox" : 
        \\    @browsers : echo "browser command"
        \\]
    ;

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    // This should produce an error because "firefox" : with nothing after colon is invalid
    const result = parser.parseWithPath(&mappings, config, "test.conf");
    try std.testing.expectError(error.ParseErrorOccurred, result);

    // TODO: our syntax design doesn't make this easy: the error is about command, but the @browsers is a process group reference
    // I don't see a easy way around this besides look ahead infinitely to make sure the next token is indeed a process group
    const parse_err = parser.error_info.?;
    try std.testing.expectEqualStrings("Command '@browsers' not found. Did you forget to define it with '.define browsers : ...'?", parse_err.message);
}

test "mode activation with process groups" {
    const allocator = std.testing.allocator;

    const config =
        \\.define terminal_apps ["kitty", "wezterm", "terminal"]
        \\.define browser_apps ["chrome", "safari", "firefox"]
        \\:: vim_mode
        \\:: browser_mode
        \\cmd - m [
        \\    @terminal_apps ; vim_mode : echo "Vim mode for terminals"
        \\    @browser_apps ; browser_mode
        \\    * ; default
        \\]
    ;

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    try parser.parseWithPath(&mappings, config, "test.conf");

    // Get the default mode and find the hotkey
    const default_mode = mappings.mode_map.getPtr("default").?;
    var it = default_mode.hotkey_map.iterator();

    var hotkey: ?*Hotkey = null;
    while (it.next()) |entry| {
        const hk = entry.key_ptr.*;
        if (hk.chords[0].key == 0x2E) { // m key
            hotkey = hk;
            break;
        }
    }

    try std.testing.expect(hotkey != null);

    // Check that all terminal apps have vim_mode activation
    const terminal_apps = [_][]const u8{ "kitty", "wezterm", "terminal" };
    for (terminal_apps) |app| {
        const cmd = hotkey.?.find_command_for_process(app);
        try std.testing.expect(cmd != null);
        switch (cmd.?) {
            .activation => |act| {
                try std.testing.expectEqualStrings("vim_mode", act.mode_name);
                try std.testing.expect(act.command != null);
                try std.testing.expectEqualStrings("echo \"Vim mode for terminals\"", act.command.?);
            },
            else => return error.WrongCommandType,
        }
    }

    // Check that all browser apps have browser_mode activation
    const browser_apps = [_][]const u8{ "chrome", "safari", "firefox" };
    for (browser_apps) |app| {
        const cmd = hotkey.?.find_command_for_process(app);
        try std.testing.expect(cmd != null);
        switch (cmd.?) {
            .activation => |act| {
                try std.testing.expectEqualStrings("browser_mode", act.mode_name);
                try std.testing.expect(act.command == null);
            },
            else => return error.WrongCommandType,
        }
    }
}

test "NX media key forwarding" {
    const allocator = std.testing.allocator;
    const c = @import("c.zig");

    // Test forwarding regular key to NX media key
    const config =
        \\# Forward delete to next media key
        \\delete | next
        \\# Forward backslash to previous media key
        \\0x2A | previous
        \\# Forward with modifiers to play
        \\cmd - p | play
    ;

    var mappings = try Mappings.init(allocator, std.testing.io);
    defer mappings.deinit();

    var parser = try Parser.init(allocator, std.testing.io);
    defer parser.deinit();

    try parser.parseWithPath(&mappings, config, "test.conf");

    const default_mode = mappings.mode_map.getPtr("default").?;
    var it = default_mode.hotkey_map.iterator();

    var found_delete = false;
    var found_backslash = false;
    var found_cmd_p = false;

    while (it.next()) |entry| {
        const hotkey = entry.key_ptr.*;

        // delete in skhd config maps to kVK_ForwardDelete = 117 (0x75)
        if (hotkey.chords[0].key == 0x75) {
            // delete | next
            const cmd = hotkey.find_command_for_process("*");
            try std.testing.expect(cmd != null);
            try std.testing.expect(cmd.? == .forwarded);
            // next is NX_KEYTYPE_NEXT = 17
            try std.testing.expect(cmd.?.forwarded.key == c.NX_KEYTYPE_NEXT);
            try std.testing.expect(cmd.?.forwarded.flags.nx == true);
            found_delete = true;
        } else if (hotkey.chords[0].key == 0x2A) {
            // backslash | previous
            const cmd = hotkey.find_command_for_process("*");
            try std.testing.expect(cmd != null);
            try std.testing.expect(cmd.? == .forwarded);
            // previous is NX_KEYTYPE_PREVIOUS = 18
            try std.testing.expect(cmd.?.forwarded.key == c.NX_KEYTYPE_PREVIOUS);
            try std.testing.expect(cmd.?.forwarded.flags.nx == true);
            found_backslash = true;
        } else if (hotkey.chords[0].key == 0x23 and hotkey.chords[0].flags.cmd) {
            // cmd - p | play
            const cmd = hotkey.find_command_for_process("*");
            try std.testing.expect(cmd != null);
            try std.testing.expect(cmd.? == .forwarded);
            // play is NX_KEYTYPE_PLAY = 16
            try std.testing.expect(cmd.?.forwarded.key == c.NX_KEYTYPE_PLAY);
            try std.testing.expect(cmd.?.forwarded.flags.nx == true);
            found_cmd_p = true;
        }
    }

    try std.testing.expect(found_delete);
    try std.testing.expect(found_backslash);
    try std.testing.expect(found_cmd_p);
}

// ---------------------------------------------------------------------------
// tools/check_c_constants.c ↔ c.zig drift check.
//
// The .c file's `_Static_assert`s catch divergence between the .c file
// and Apple's SDK at build time (`zig build check-c-constants`). This
// test catches divergence in the *other* direction: c.zig changing
// without the .c file being updated. With both checks in place, all
// three (SDK / .c / c.zig) must agree.
//
// We parse `_Static_assert(LHS == RHS, "NAME");` lines at comptime,
// look up `c.<NAME>`, and compare its value to RHS. Mismatches surface
// as @compileError pointing at the offending constant.

fn parseCExpr(comptime expr: []const u8) i128 {
    var s = std.mem.trim(u8, expr, " \t");

    // Strip a leading "(unsigned)" cast — purely a width hint, doesn't
    // affect the integer's value.
    if (std.mem.startsWith(u8, s, "(unsigned)")) {
        s = std.mem.trim(u8, s["(unsigned)".len..], " \t");
    }
    // Strip a leading "(int)" cast and sign-extend if the literal has
    // the high bit set — this is the C convention for IOReturn-style
    // negative-int constants spelled as `(int)0xE0000XXX`.
    var is_int_cast = false;
    if (std.mem.startsWith(u8, s, "(int)")) {
        is_int_cast = true;
        s = std.mem.trim(u8, s["(int)".len..], " \t");
    }

    // Strip wrapping parens.
    while (s.len >= 2 and s[0] == '(' and s[s.len - 1] == ')') {
        // Don't strip "(1 << 0)" prematurely — we still want the parens
        // gone so the shift parser below sees plain "1 << 0".
        s = std.mem.trim(u8, s[1 .. s.len - 1], " \t");
    }

    // Handle `LHS << RHS`. Recurse so each side gets its own stripping.
    if (std.mem.indexOf(u8, s, "<<")) |op| {
        const lhs = parseCExpr(std.mem.trim(u8, s[0..op], " \t"));
        const rhs = parseCExpr(std.mem.trim(u8, s[op + 2 ..], " \t"));
        return lhs << @intCast(rhs);
    }

    // Strip integer suffixes. Order matters (longest first).
    inline for (.{ "ULL", "ull", "LL", "ll", "UL", "ul", "U", "u", "L", "l" }) |suf| {
        if (std.mem.endsWith(u8, s, suf)) {
            s = s[0 .. s.len - suf.len];
            break;
        }
    }

    const value = std.fmt.parseInt(u128, s, 0) catch |err| @compileError(
        std.fmt.comptimePrint("parseCExpr can't parse '{s}': {s}", .{ s, @errorName(err) }),
    );
    if (is_int_cast and value > std.math.maxInt(i32)) {
        // Sign-extend from 32-bit.
        return @as(i32, @bitCast(@as(u32, @intCast(value))));
    }
    return @intCast(value);
}

test "tools/check_c_constants.c values agree with c.zig" {
    const c = @import("c.zig");
    const src = @embedFile("check_c_constants_c");

    @setEvalBranchQuota(1_000_000);
    comptime var line_iter = std.mem.tokenizeScalar(u8, src, '\n');
    inline while (comptime line_iter.next()) |line| {
        const trimmed = comptime std.mem.trim(u8, line, " \t");
        if (comptime !std.mem.startsWith(u8, trimmed, "_Static_assert(")) continue;

        // Body: everything between the first `(` and the trailing `);`.
        const body = comptime blk: {
            const start = std.mem.indexOfScalar(u8, trimmed, '(').? + 1;
            // Find the matching closing paren of `_Static_assert(...)`.
            // The body contains a string literal but no nested unbalanced
            // parens, so a last-`)` scan is fine.
            const end = std.mem.lastIndexOfScalar(u8, trimmed, ')').?;
            break :blk trimmed[start..end];
        };

        // Split on the *last* top-level `,` — the value side may contain
        // commas inside casts in the future, so prefer last over first.
        const last_comma = comptime std.mem.lastIndexOfScalar(u8, body, ',').?;
        const lhs_eq_rhs = comptime std.mem.trim(u8, body[0..last_comma], " \t");
        const name_quoted = comptime std.mem.trim(u8, body[last_comma + 1 ..], " \t");
        const name = comptime std.mem.trim(u8, name_quoted, "\"");

        // Split LHS == RHS.
        const eq = comptime std.mem.indexOf(u8, lhs_eq_rhs, "==").?;
        const rhs_str = comptime std.mem.trim(u8, lhs_eq_rhs[eq + 2 ..], " \t");
        const expected: i128 = comptime parseCExpr(rhs_str);

        if (!@hasDecl(c, name)) {
            @compileError("tools/check_c_constants.c references unknown c." ++ name);
        }
        const actual: i128 = comptime @intCast(@field(c, name));
        if (comptime actual != expected) {
            @compileError(std.fmt.comptimePrint(
                "drift between c.{s} ({d}) and tools/check_c_constants.c ({d}); update both",
                .{ name, actual, expected },
            ));
        }
    }
}
