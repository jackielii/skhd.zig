const std = @import("std");
const EventTap = @import("EventTap.zig");
const Mappings = @import("Mappings.zig");
const Parser = @import("Parser.zig");
const Hotkey = @import("Hotkey.zig");
const Mode = @import("Mode.zig");
const ModifierFlag = @import("Keycodes.zig").ModifierFlag;
const Logger = @import("Logger.zig");
const Hotload = @import("Hotload.zig");
const c = @import("c.zig");

const Skhd = @This();

// Global reference for signal handler
var global_skhd: ?*Skhd = null;

allocator: std.mem.Allocator,
mappings: Mappings,
current_mode: ?*Mode = null,
event_tap: EventTap,
config_file: []const u8,
logger: Logger,
hotloader: ?Hotload = null,
hotload_enabled: bool = false,

pub fn init(allocator: std.mem.Allocator, config_file: []const u8, mode: Logger.Mode) !Skhd {
    // Initialize logger first
    var logger = try Logger.init(allocator, mode);
    errdefer logger.deinit();

    try logger.logInfo("Initializing skhd with config: {s}", .{config_file});

    var mappings = try Mappings.init(allocator);
    errdefer mappings.deinit();

    // Parse configuration file
    var parser = try Parser.init(allocator);
    defer parser.deinit();

    const content = try std.fs.cwd().readFileAlloc(allocator, config_file, 1 << 20); // 1MB max
    defer allocator.free(content);

    parser.parseWithPath(&mappings, content, config_file) catch |err| {
        if (err == error.ParseErrorOccurred) {
            // Parse errors have already been logged by the parser
            return err;
        }
        return err;
    };

    // Process any .load directives
    try parser.processLoadDirectives(&mappings);

    // Initialize with default mode if exists
    var current_mode: ?*Mode = null;
    if (mappings.mode_map.getPtr("default")) |default_mode| {
        current_mode = default_mode;
    }

    // Log loaded modes
    var mode_iter = mappings.mode_map.iterator();
    var modes_list = std.ArrayList(u8).init(allocator);
    defer modes_list.deinit();
    while (mode_iter.next()) |entry| {
        try modes_list.writer().print("'{s}' ", .{entry.key_ptr.*});
    }
    try logger.logInfo("Loaded modes: {s}", .{modes_list.items});

    // Log shell configuration
    try logger.logInfo("Using shell: {s}", .{mappings.shell});

    // Log blacklisted applications
    if (mappings.blacklist.count() > 0) {
        var blacklist_iter = mappings.blacklist.keyIterator();
        var blacklist_buf = std.ArrayList(u8).init(allocator);
        defer blacklist_buf.deinit();
        while (blacklist_iter.next()) |app| {
            try blacklist_buf.writer().print("{s} ", .{app.*});
        }
        try logger.logInfo("Blacklisted applications: {s}", .{blacklist_buf.items});
    }

    // Create event tap with keyboard and system defined events
    const mask: u32 = (1 << c.kCGEventKeyDown) | (1 << c.NX_SYSDEFINED);

    return Skhd{
        .allocator = allocator,
        .mappings = mappings,
        .current_mode = current_mode,
        .event_tap = EventTap{ .mask = mask },
        .config_file = try allocator.dupe(u8, config_file),
        .logger = logger,
    };
}

pub fn deinit(self: *Skhd) void {
    if (self.hotloader) |*hotloader| {
        hotloader.deinit();
    }
    self.event_tap.deinit();
    self.mappings.deinit();
    self.allocator.free(self.config_file);
    self.logger.deinit();
}

pub fn run(self: *Skhd, enable_hotload: bool) !void {
    // Set up signal handler for config reload
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleSigusr1 },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.USR1, &act, null);

    // Store a global reference for the signal handler
    global_skhd = self;

    // Enable hot reload if requested (must be done before run loop starts)
    if (enable_hotload) {
        try self.enableHotReload();
    }

    // Set up event tap (but don't start run loop yet)
    try self.logger.logInfo("Starting event tap", .{});
    try self.event_tap.begin(keyHandler, self);

    // Call NSApplicationLoad() like the original skhd
    c.NSApplicationLoad();

    // Now start the run loop - this will handle both event tap and FSEvents
    c.CFRunLoopRun();
}

fn keyHandler(proxy: c.CGEventTapProxy, typ: c.CGEventType, event: c.CGEventRef, user_info: ?*anyopaque) callconv(.c) c.CGEventRef {
    _ = proxy;

    const self = @as(*Skhd, @ptrCast(@alignCast(user_info)));

    switch (typ) {
        c.kCGEventTapDisabledByTimeout, c.kCGEventTapDisabledByUserInput => {
            self.logger.logInfo("Restarting event-tap", .{}) catch {};
            c.CGEventTapEnable(self.event_tap.handle, true);
            return event;
        },
        c.kCGEventKeyDown => {
            return self.handleKeyDown(event) catch |err| {
                self.logger.logError("Error handling key down: {}", .{err}) catch {};
                return event;
            };
        },
        c.NX_SYSDEFINED => {
            return self.handleSystemKey(event) catch |err| {
                self.logger.logError("Error handling system key: {}", .{err}) catch {};
                return event;
            };
        },
        else => return event,
    }
}

fn handleKeyDown(self: *Skhd, event: c.CGEventRef) !c.CGEventRef {
    if (self.current_mode == null) return event;

    // Check if current application is blacklisted
    const process_name = try getCurrentProcessName(self.allocator);
    defer self.allocator.free(process_name);

    if (self.mappings.blacklist.contains(process_name)) {
        return event;
    }

    // Create hotkey from event
    const eventkey = createEventKey(event);

    // First check for key forwarding
    if (try self.findAndForwardHotkey(&eventkey, event)) {
        return event;
    }

    // Then check for regular hotkey execution
    if (try self.findAndExecHotkey(&eventkey)) {
        // Hotkey was handled, consume the event by returning null
        // In Zig, we need to cast this properly for the C callback
        return @ptrFromInt(0);
    }

    return event;
}

fn handleSystemKey(self: *Skhd, event: c.CGEventRef) !c.CGEventRef {
    if (self.current_mode == null) return event;

    // Check if current application is blacklisted
    const process_name = try getCurrentProcessName(self.allocator);
    defer self.allocator.free(process_name);

    if (self.mappings.blacklist.contains(process_name)) {
        return event;
    }

    var eventkey: Hotkey.KeyPress = undefined;
    if (interceptSystemKey(event, &eventkey)) {
        if (try self.findAndExecHotkey(&eventkey)) {
            return @ptrFromInt(0);
        }
    }

    return event;
}

fn createEventKey(event: c.CGEventRef) Hotkey.KeyPress {
    return .{
        .key = @intCast(c.CGEventGetIntegerValueField(event, c.kCGKeyboardEventKeycode)),
        .flags = cgeventFlagsToHotkeyFlags(c.CGEventGetFlags(event)),
    };
}

fn cgeventFlagsToHotkeyFlags(event_flags: c.CGEventFlags) ModifierFlag {
    var flags = ModifierFlag{};

    // Implement left/right modifier distinction like original skhd
    // Alt/Option modifiers
    if (event_flags & c.kCGEventFlagMaskAlternate != 0) {
        const left_alt = (event_flags & 0x00000020) != 0; // Event_Mask_LAlt
        const right_alt = (event_flags & 0x00000040) != 0; // Event_Mask_RAlt

        if (left_alt) {
            flags.lalt = true;
        }
        if (right_alt) {
            flags.ralt = true;
        }
        if (!left_alt and !right_alt) {
            flags.alt = true;
        }
    }

    // Shift modifiers
    if (event_flags & c.kCGEventFlagMaskShift != 0) {
        const left_shift = (event_flags & 0x00000002) != 0; // Event_Mask_LShift
        const right_shift = (event_flags & 0x00000004) != 0; // Event_Mask_RShift

        if (left_shift) {
            flags.lshift = true;
        }
        if (right_shift) {
            flags.rshift = true;
        }
        if (!left_shift and !right_shift) {
            flags.shift = true;
        }
    }

    // Command modifiers
    if (event_flags & c.kCGEventFlagMaskCommand != 0) {
        const left_cmd = (event_flags & 0x00000008) != 0; // Event_Mask_LCmd
        const right_cmd = (event_flags & 0x00000010) != 0; // Event_Mask_RCmd

        if (left_cmd) {
            flags.lcmd = true;
        }
        if (right_cmd) {
            flags.rcmd = true;
        }
        if (!left_cmd and !right_cmd) {
            flags.cmd = true;
        }
    }

    // Control modifiers
    if (event_flags & c.kCGEventFlagMaskControl != 0) {
        const left_ctrl = (event_flags & 0x00000001) != 0; // Event_Mask_LControl
        const right_ctrl = (event_flags & 0x00002000) != 0; // Event_Mask_RControl

        if (left_ctrl) {
            flags.lcontrol = true;
        }
        if (right_ctrl) {
            flags.rcontrol = true;
        }
        if (!left_ctrl and !right_ctrl) {
            flags.control = true;
        }
    }

    // Function key modifier
    if (event_flags & c.kCGEventFlagMaskSecondaryFn != 0) {
        flags.@"fn" = true;
    }

    return flags;
}

fn interceptSystemKey(event: c.CGEventRef, eventkey: *Hotkey.KeyPress) bool {
    const event_data = c.CGEventCreateData(c.kCFAllocatorDefault, event);
    defer c.CFRelease(event_data);

    const data = c.CFDataGetBytePtr(event_data);
    const key_code = data[129];
    const key_state = data[130];
    const key_stype = data[123];

    const NX_KEYDOWN: u8 = 0x0A;
    const NX_SUBTYPE_AUX_CONTROL_BUTTONS: u8 = 8;

    const result = (key_state == NX_KEYDOWN) and (key_stype == NX_SUBTYPE_AUX_CONTROL_BUTTONS);

    if (result) {
        eventkey.key = key_code;
        eventkey.flags = cgeventFlagsToHotkeyFlags(c.CGEventGetFlags(event));
        eventkey.flags.nx = true;
    }

    return result;
}

fn forwardKey(target_key: Hotkey.KeyPress, original_event: c.CGEventRef) !bool {
    // Modify the original event directly (like the original skhd implementation)
    // This prevents the original key from being sent and sends the target key instead

    // Set the new keycode
    c.CGEventSetIntegerValueField(original_event, c.kCGKeyboardEventKeycode, @intCast(target_key.key));

    // Set the new modifier flags
    const target_flags = hotkeyFlagsToCGEventFlags(target_key.flags);
    c.CGEventSetFlags(original_event, target_flags);

    return true;
}

fn hotkeyFlagsToCGEventFlags(hotkey_flags: ModifierFlag) c.CGEventFlags {
    var flags: c.CGEventFlags = 0;

    // Handle command modifiers (general, left, right)
    if (hotkey_flags.cmd or hotkey_flags.lcmd or hotkey_flags.rcmd) {
        flags |= c.kCGEventFlagMaskCommand;
        if (hotkey_flags.lcmd) {
            flags |= 0x00000008; // Event_Mask_LCmd
        }
        if (hotkey_flags.rcmd) {
            flags |= 0x00000010; // Event_Mask_RCmd
        }
    }

    // Handle alt modifiers (general, left, right)
    if (hotkey_flags.alt or hotkey_flags.lalt or hotkey_flags.ralt) {
        flags |= c.kCGEventFlagMaskAlternate;
        if (hotkey_flags.lalt) {
            flags |= 0x00000020; // Event_Mask_LAlt
        }
        if (hotkey_flags.ralt) {
            flags |= 0x00000040; // Event_Mask_RAlt
        }
    }

    // Handle control modifiers (general, left, right)
    if (hotkey_flags.control or hotkey_flags.lcontrol or hotkey_flags.rcontrol) {
        flags |= c.kCGEventFlagMaskControl;
        if (hotkey_flags.lcontrol) {
            flags |= 0x00000001; // Event_Mask_LControl
        }
        if (hotkey_flags.rcontrol) {
            flags |= 0x00002000; // Event_Mask_RControl
        }
    }

    // Handle shift modifiers (general, left, right)
    if (hotkey_flags.shift or hotkey_flags.lshift or hotkey_flags.rshift) {
        flags |= c.kCGEventFlagMaskShift;
        if (hotkey_flags.lshift) {
            flags |= 0x00000002; // Event_Mask_LShift
        }
        if (hotkey_flags.rshift) {
            flags |= 0x00000004; // Event_Mask_RShift
        }
    }

    // Function key modifier
    if (hotkey_flags.@"fn") {
        flags |= c.kCGEventFlagMaskSecondaryFn;
    }

    return flags;
}

fn findAndForwardHotkey(self: *Skhd, eventkey: *const Hotkey.KeyPress, event: c.CGEventRef) !bool {
    // Create a temporary hotkey struct for lookup
    var lookup_hotkey = try Hotkey.create(self.allocator);
    defer lookup_hotkey.destroy();

    lookup_hotkey.key = eventkey.key;
    lookup_hotkey.flags = eventkey.flags;

    // Look up hotkey in current mode
    const mode = self.current_mode orelse return false;

    // Find matching hotkey in the mode
    var found_hotkey: ?*Hotkey = null;
    var it = mode.hotkey_map.iterator();
    while (it.next()) |entry| {
        const hotkey = entry.key_ptr.*;
        if (Hotkey.eql(hotkey, lookup_hotkey)) {
            found_hotkey = hotkey;
            break;
        }
    }

    if (found_hotkey) |hotkey| {
        // Get current process name
        const process_name = try getCurrentProcessName(self.allocator);
        defer self.allocator.free(process_name);

        // Check for forwarded key in process-specific commands
        for (hotkey.process_names.items, 0..) |proc_name, i| {
            if (std.mem.eql(u8, proc_name, process_name)) {
                if (i < hotkey.commands.items.len) {
                    switch (hotkey.commands.items[i]) {
                        .forwarded => |target_key| {
                            self.logger.logDebug("Forwarding key for process '{s}'", .{process_name}) catch {};
                            return try forwardKey(target_key, event);
                        },
                        else => {}, // Not a forwarded key
                    }
                }
                break;
            }
        }

        // Check wildcard forwarding
        if (hotkey.wildcard_command) |wildcard| {
            switch (wildcard) {
                .forwarded => |target_key| {
                    self.logger.logDebug("Forwarding key (wildcard)", .{}) catch {};
                    return try forwardKey(target_key, event);
                },
                else => {}, // Not a forwarded key
            }
        }
    }

    return false;
}

fn findAndExecHotkey(self: *Skhd, eventkey: *const Hotkey.KeyPress) !bool {
    // Create a temporary hotkey struct for lookup
    var lookup_hotkey = try Hotkey.create(self.allocator);
    defer lookup_hotkey.destroy();

    lookup_hotkey.key = eventkey.key;
    lookup_hotkey.flags = eventkey.flags;

    // Look up hotkey in current mode
    const mode = self.current_mode orelse return false;

    // Find matching hotkey in the mode
    var found_hotkey: ?*Hotkey = null;
    var it = mode.hotkey_map.iterator();
    while (it.next()) |entry| {
        const hotkey = entry.key_ptr.*;
        if (Hotkey.eql(hotkey, lookup_hotkey)) {
            found_hotkey = hotkey;
            break;
        }
    }

    if (found_hotkey) |hotkey| {
        self.logger.logDebug("Found hotkey match - key: {d}, flags: {any} in mode '{s}'", .{ hotkey.key, hotkey.flags, mode.name }) catch {};

        // Get current process name for process-specific commands
        const process_name = try getCurrentProcessName(self.allocator);
        defer self.allocator.free(process_name);

        self.logger.logDebug("Current process name: '{s}'", .{process_name}) catch {};

        // Check for mode activation
        if (hotkey.flags.activate) {
            self.logger.logDebug("Mode activation hotkey triggered", .{}) catch {};
            // Get the mode name from the command
            if (hotkey.wildcard_command) |cmd| {
                switch (cmd) {
                    .command => |mode_name| {
                        self.logger.logDebug("Attempting to switch to mode '{s}'", .{mode_name}) catch {};
                        // Try to find the mode
                        const new_mode = self.mappings.mode_map.getPtr(mode_name);

                        if (new_mode) |target_mode| {
                            self.current_mode = target_mode;
                            self.logger.logInfo("Switched to mode '{s}'", .{target_mode.name}) catch {};
                            // Execute mode command if exists
                            if (target_mode.command) |mode_cmd| {
                                try self.executeCommand(self.mappings.shell, mode_cmd);
                            }
                            return true;
                        } else if (std.mem.eql(u8, mode_name, "default")) {
                            // Switching to default mode which should always exist
                            if (self.mappings.mode_map.getPtr("default")) |default_mode| {
                                self.current_mode = default_mode;
                                self.logger.logInfo("Switched to default mode", .{}) catch {};
                                return true;
                            }
                        }

                        // If we get here, mode wasn't found but we should still consume the event
                        // since this is a mode activation hotkey
                        return true;
                    },
                    else => {
                        self.logger.logDebug("Activate flag set but no command found", .{}) catch {};
                    },
                }
            } else {
                self.logger.logDebug("Activate flag set but no wildcard_command", .{}) catch {};
            }
            return false;
        }

        // Find command to execute
        var command_to_exec: ?[]const u8 = null;

        // Check process-specific commands
        for (hotkey.process_names.items, 0..) |proc_name, i| {
            self.logger.logDebug("Checking process '{s}' against current '{s}'", .{ proc_name, process_name }) catch {};
            if (std.mem.eql(u8, proc_name, process_name)) {
                self.logger.logDebug("Process match found for '{s}'", .{process_name}) catch {};
                if (i < hotkey.commands.items.len) {
                    switch (hotkey.commands.items[i]) {
                        .command => |cmd| {
                            command_to_exec = cmd;
                            self.logger.logDebug("Using process-specific command: '{s}'", .{cmd}) catch {};
                        },
                        .unbound => {
                            self.logger.logDebug("key is unbound for process '{s}'", .{process_name}) catch {};
                            return false; // Unbound key
                        },
                        .forwarded => |_| {
                            self.logger.logDebug("Forwarding key for process '{s}'", .{process_name}) catch {};
                            // Note: We should only reach here if findAndForwardHotkey didn't handle it
                            // This shouldn't happen with current logic, but handling for completeness
                            return false;
                        },
                    }
                }
                break;
            }
        }

        // If no process-specific command found, use wildcard
        if (command_to_exec == null) {
            if (hotkey.wildcard_command) |wildcard| {
                switch (wildcard) {
                    .command => |cmd| command_to_exec = cmd,
                    .unbound => return false,
                    .forwarded => |_| {
                        self.logger.logDebug("Forwarding key (wildcard)", .{}) catch {};
                        // Note: We should only reach here if findAndForwardHotkey didn't handle it
                        return false;
                    },
                }
            }
        }

        // Execute the command
        if (command_to_exec) |cmd| {
            try self.executeCommand(self.mappings.shell, cmd);
            return !hotkey.flags.passthrough;
        }
    }

    return false;
}

fn executeCommand(self: *Skhd, shell: []const u8, command: []const u8) !void {
    // Log the command execution
    try self.logger.logInfo("Executing command: {s}", .{command});

    const argv = [_][]const u8{ shell, "-c", command };

    var child = std.process.Child.init(&argv, self.allocator);
    child.stdin_behavior = .Ignore;

    // In interactive mode, capture and display output
    if (self.logger.mode == .interactive) {
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        // Read output synchronously to avoid race conditions
        self.readChildOutputSync(&child) catch {};
    } else {
        // In service mode, ignore output
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();
    }

    // Note: Differences from the original C implementation:
    // 1. The C version uses fork() + setsid() + execvp() to fully detach the child process
    //    - setsid() creates a new session, preventing the child from receiving terminal signals
    //    - Zig's std.process.Child doesn't support setsid() directly
    // 2. The C version sets signal(SIGCHLD, SIG_IGN) to automatically reap zombie children
    //    - Without this, child processes remain as zombies until skhd exits
    //    - We could add SIGCHLD handling in main.zig if zombie processes become an issue
    // 3. Both implementations run commands asynchronously without waiting for completion
    //
    // For most use cases this should work fine, but be aware that:
    // - Child processes will remain in the same session as skhd
    // - Zombie processes will accumulate until skhd exits

    // Don't wait for the child to finish - let it run in background
}

fn getCurrentProcessName(allocator: std.mem.Allocator) ![]const u8 {
    var psn: c.ProcessSerialNumber = undefined;

    // Get the frontmost process
    const status = c.GetFrontProcess(&psn);
    if (status != c.noErr) {
        return try allocator.dupe(u8, "unknown");
    }

    // Get the process name
    var process_name_ref: c.CFStringRef = undefined;
    const copy_status = c.CopyProcessName(&psn, &process_name_ref);
    if (copy_status != c.noErr) {
        return try allocator.dupe(u8, "unknown");
    }
    defer c.CFRelease(process_name_ref);

    // Convert CFString to C string
    const max_size = c.CFStringGetMaximumSizeForEncoding(c.CFStringGetLength(process_name_ref), c.kCFStringEncodingUTF8);
    var buffer = try allocator.alloc(u8, @intCast(max_size + 1));
    defer allocator.free(buffer);

    const success = c.CFStringGetCString(process_name_ref, buffer.ptr, @intCast(buffer.len), c.kCFStringEncodingUTF8);
    if (success == 0) {
        return try allocator.dupe(u8, "unknown");
    }

    // Find the actual length of the string
    const c_string_len = std.mem.len(@as([*:0]const u8, @ptrCast(buffer.ptr)));
    const name = buffer[0..c_string_len];

    // Convert to lowercase to match original skhd behavior
    var result = try allocator.alloc(u8, name.len);
    for (name, 0..) |char, i| {
        result[i] = std.ascii.toLower(char);
    }

    return result;
}
/// Signal handler for SIGUSR1 - reload configuration
fn handleSigusr1(_: c_int) callconv(.C) void {
    if (global_skhd) |skhd| {
        skhd.logger.logInfo("Received SIGUSR1, reloading configuration", .{}) catch {};
        skhd.reloadConfig() catch |err| {
            skhd.logger.logError("Failed to reload config: {}", .{err}) catch {};
        };
    }
}

/// Reload configuration from file
pub fn reloadConfig(self: *Skhd) !void {
    try self.logger.logInfo("Reloading configuration from: {s}", .{self.config_file});

    // Parse new configuration
    var new_mappings = try Mappings.init(self.allocator);
    errdefer new_mappings.deinit();

    var parser = try Parser.init(self.allocator);
    defer parser.deinit();

    const content = try std.fs.cwd().readFileAlloc(self.allocator, self.config_file, 1 << 20);
    defer self.allocator.free(content);

    parser.parseWithPath(&new_mappings, content, self.config_file) catch |err| {
        if (err == error.ParseErrorOccurred) {
            // Log the parse error with proper formatting
            if (parser.getError()) |parse_err| {
                try self.logger.logError("skhd: {}", .{parse_err});
            }
            return err;
        }
        return err;
    };
    try parser.processLoadDirectives(&new_mappings);

    // Swap old mappings with new ones
    self.mappings.deinit();
    self.mappings = new_mappings;

    // Reset to default mode
    if (self.mappings.mode_map.getPtr("default")) |default_mode| {
        self.current_mode = default_mode;
    } else {
        self.current_mode = null;
    }

    try self.logger.logInfo("Configuration reloaded successfully", .{});
}

pub fn enableHotReload(self: *Skhd) !void {
    if (self.hotload_enabled) return;

    try self.logger.logInfo("Enabling hot reload...", .{});

    // Create hotloader
    var hotloader = Hotload.init(self.allocator, hotloadCallback);

    try self.logger.logInfo("Watching file: {s}", .{self.config_file});
    try hotloader.watchFile(self.config_file);

    self.hotloader = hotloader;
    self.hotload_enabled = true;

    try self.logger.logInfo("Hot reload enabled successfully", .{});
}

pub fn disableHotReload(self: *Skhd) void {
    if (!self.hotload_enabled) return;

    if (self.hotloader) |*hotloader| {
        hotloader.stop();
    }

    self.hotloader = null;
    self.hotload_enabled = false;

    self.logger.logInfo("Hot reload disabled", .{}) catch {};
}

fn hotloadCallback(path: []const u8) void {
    _ = path;

    // FSEvents callbacks can run on different threads
    // Send SIGUSR1 to trigger reload from main thread
    // Use C directly to avoid any Zig runtime issues
    const pid = std.c.getpid();
    _ = std.c.kill(pid, 10); // SIGUSR1 = 10
}
/// Read child process output synchronously
fn readChildOutputSync(self: *Skhd, child: *std.process.Child) !void {
    var stdout_data = std.ArrayListUnmanaged(u8){};
    defer stdout_data.deinit(self.allocator);
    var stderr_data = std.ArrayListUnmanaged(u8){};
    defer stderr_data.deinit(self.allocator);

    // Collect all output first
    try child.collectOutput(self.allocator, &stdout_data, &stderr_data, 8192);

    // Wait for child to finish
    _ = try child.wait();

    // Log stdout if not empty
    if (stdout_data.items.len > 0) {
        var lines = std.mem.tokenizeScalar(u8, stdout_data.items, '\n');
        while (lines.next()) |line| {
            try self.logger.logInfo("  stdout: {s}", .{line});
        }
    }

    // Log stderr if not empty
    if (stderr_data.items.len > 0) {
        var lines = std.mem.tokenizeScalar(u8, stderr_data.items, '\n');
        while (lines.next()) |line| {
            try self.logger.logError("  stderr: {s}", .{line});
        }
    }
}
