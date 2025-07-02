const std = @import("std");
const builtin = @import("builtin");
const EventTap = @import("EventTap.zig");
const Mappings = @import("Mappings.zig");
const Parser = @import("Parser.zig");
const Hotkey = @import("Hotkey.zig");
const Mode = @import("Mode.zig");
const Keycodes = @import("Keycodes.zig");
const ModifierFlag = Keycodes.ModifierFlag;
const Logger = @import("Logger.zig");
const Hotload = @import("Hotload.zig");
const Tracer = @import("Tracer.zig");
const CarbonEvent = @import("CarbonEvent.zig");
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
hotloader: ?*Hotload = null,
hotload_enabled: bool = false,
tracer: Tracer,
carbon_event: *CarbonEvent,

pub fn init(allocator: std.mem.Allocator, config_file: []const u8, mode: Logger.Mode, profile: bool) !Skhd {
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
            // Log the parse error with proper formatting
            if (parser.getError()) |parse_err| {
                logger.logError("skhd: {}", .{parse_err}) catch {};
            }
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

    // Initialize Carbon event handler for app switching
    var carbon_event = try CarbonEvent.init(allocator);
    errdefer carbon_event.deinit();

    try logger.logInfo("Initial process: {s}", .{carbon_event.process_name});

    // Create event tap with keyboard and system defined events
    const mask: u32 = (1 << c.kCGEventKeyDown) | (1 << c.NX_SYSDEFINED);

    return Skhd{
        .allocator = allocator,
        .mappings = mappings,
        .current_mode = current_mode,
        .event_tap = EventTap{ .mask = mask },
        .config_file = try allocator.dupe(u8, config_file),
        .logger = logger,
        .tracer = Tracer.init(profile),
        .carbon_event = carbon_event,
    };
}

pub fn deinit(self: *Skhd) void {
    // Print tracer summary before cleanup
    if (self.tracer.enabled) {
        const stderr = std.io.getStdErr().writer();
        self.tracer.printSummary(stderr) catch {};
    }

    if (self.hotloader) |hotloader| {
        hotloader.destroy();
    }
    self.carbon_event.deinit();
    self.event_tap.deinit();
    self.mappings.deinit();
    self.allocator.free(self.config_file);
    self.logger.deinit();
}

pub fn run(self: *Skhd, enable_hotload: bool) !void {
    // Set up signal handler for config reload
    const usr1_act = std.posix.Sigaction{
        .handler = .{ .handler = handleSigusr1 },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.USR1, &usr1_act, null);

    // Set up signal handler for SIGINT (Ctrl+C) to print trace summary
    const int_act = std.posix.Sigaction{
        .handler = .{ .handler = handleSigint },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &int_act, null);

    // Store a global reference for the signal handler
    global_skhd = self;

    // Check if config file is a regular file
    const stat = std.fs.cwd().statFile(self.config_file) catch |err| {
        try self.logger.logError("Cannot stat config file {s}: {}", .{ self.config_file, err });
        return err;
    };

    if (stat.kind != .file) {
        try self.logger.logError("Config file {s} is not a regular file", .{self.config_file});
        return error.InvalidConfigFile;
    }

    // Enable hot reload if requested (must be done before run loop starts)
    if (enable_hotload) {
        try self.enableHotReload();
    }

    // Set up event tap (but don't start run loop yet)
    try self.logger.logInfo("Starting event tap", .{});
    self.event_tap.begin(keyHandler, self) catch |err| {
        if (err == error.AccessibilityPermissionDenied) {
            const allocated_path: ?[]u8 = std.fs.selfExePathAlloc(self.allocator) catch null;
            defer if (allocated_path) |path| self.allocator.free(path);
            const exe_path = allocated_path orelse "/opt/homebrew/bin/skhd";

            try self.logger.logError("\n" ++
                "=====================================================\n" ++
                "ACCESSIBILITY PERMISSIONS REQUIRED\n" ++
                "=====================================================\n" ++
                "skhd requires accessibility permissions to function.\n" ++
                "\n" ++
                "Please grant accessibility permissions:\n" ++
                "1. Open System Settings → Privacy & Security → Accessibility\n" ++
                "2. Click the lock to make changes\n" ++
                "3. Add this binary: {s}\n" ++
                "4. Make sure it's enabled (checkbox checked)\n" ++
                "5. Restart skhd\n" ++
                "\n" ++
                "Troubleshooting:\n" ++
                "If skhd is already listed but still not working:\n" ++
                "- Remove the existing skhd entry\n" ++
                "- Stop the service: skhd --stop-service\n" ++
                "- Re-add skhd to the list " ++
                "- Or just restart the service to see the entry added\n" ++
                "- Enable the entry and run skhd --restart-service\n" ++
                "=====================================================\n", .{exe_path});
        }
        return err;
    };

    // Call NSApplicationLoad() like the original skhd
    c.NSApplicationLoad();

    // Always log successful event tap creation
    try self.logger.logAlways("Event tap created successfully. skhd is now running.", .{});

    // Now start the run loop - this will handle both event tap and FSEvents
    c.CFRunLoopRun();

    // If we get here, the run loop has exited
    try self.logger.logInfo("Run loop exited", .{});
}

fn keyHandler(proxy: c.CGEventTapProxy, typ: c.CGEventType, event: c.CGEventRef, user_info: ?*anyopaque) callconv(.c) c.CGEventRef {
    _ = proxy;

    const self = @as(*Skhd, @ptrCast(@alignCast(user_info)));
    self.tracer.traceKeyEvent();

    switch (typ) {
        c.kCGEventTapDisabledByTimeout, c.kCGEventTapDisabledByUserInput => {
            self.logger.logInfo("Restarting event-tap", .{}) catch {};
            c.CGEventTapEnable(self.event_tap.handle, true);
            return event;
        },
        c.kCGEventKeyDown => {
            self.tracer.traceKeyDown();
            return self.handleKeyDown(event) catch |err| {
                self.logger.logError("Error handling key down: {}", .{err}) catch {};
                return event;
            };
        },
        c.NX_SYSDEFINED => {
            self.tracer.traceSystemKey();
            return self.handleSystemKey(event) catch |err| {
                self.logger.logError("Error handling system key: {}", .{err}) catch {};
                return event;
            };
        },
        else => return event,
    }
}

inline fn handleKeyDown(self: *Skhd, event: c.CGEventRef) !c.CGEventRef {
    if (self.current_mode == null) {
        self.tracer.traceNoModeExit();
        return event;
    }

    // Skip events that we generated ourselves to avoid loops
    const marker = c.CGEventGetIntegerValueField(event, c.kCGEventSourceUserData);
    if (marker == SKHD_EVENT_MARKER) {
        self.tracer.traceSelfGeneratedExit();
        return event;
    }

    // Check if current application is blacklisted (using cached name)
    self.tracer.traceProcessNameLookup();
    const process_name = self.carbon_event.getProcessName();

    if (self.mappings.blacklist.contains(process_name)) {
        self.tracer.traceBlacklistedExit();
        return event;
    }

    // Create hotkey from event
    const eventkey = createEventKey(event);

    // Single lookup to handle both forwarding and execution
    if (try self.processHotkey(&eventkey, event, process_name)) {
        // Hotkey was handled (forwarded or executed), consume the event
        return @ptrFromInt(0);
    }

    try self.logKeyPress("No matching hotkey found for key: {s}, process name: {s}", eventkey, process_name);
    return event;
}

inline fn handleSystemKey(self: *Skhd, event: c.CGEventRef) !c.CGEventRef {
    if (self.current_mode == null) {
        self.tracer.traceNoModeExit();
        return event;
    }

    // Skip events that we generated ourselves to avoid loops
    const marker = c.CGEventGetIntegerValueField(event, c.kCGEventSourceUserData);
    if (marker == SKHD_EVENT_MARKER) {
        self.tracer.traceSelfGeneratedExit();
        return event;
    }

    // Check if current application is blacklisted (using cached name)
    self.tracer.traceProcessNameLookup();
    const process_name = self.carbon_event.getProcessName();

    if (self.mappings.blacklist.contains(process_name)) {
        self.tracer.traceBlacklistedExit();
        return event;
    }

    var eventkey: Hotkey.KeyPress = undefined;
    if (interceptSystemKey(event, &eventkey)) {
        // Single lookup to handle both forwarding and execution
        if (try self.processHotkey(&eventkey, event, process_name)) {
            return @ptrFromInt(0);
        }
    }

    return event;
}

inline fn createEventKey(event: c.CGEventRef) Hotkey.KeyPress {
    return .{
        .key = @intCast(c.CGEventGetIntegerValueField(event, c.kCGKeyboardEventKeycode)),
        .flags = cgeventFlagsToHotkeyFlags(c.CGEventGetFlags(event)),
    };
}

inline fn cgeventFlagsToHotkeyFlags(event_flags: c.CGEventFlags) ModifierFlag {
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

inline fn interceptSystemKey(event: c.CGEventRef, eventkey: *Hotkey.KeyPress) bool {
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

// Magic number to mark events generated by us
const SKHD_EVENT_MARKER: i64 = 0x736B6864; // "skhd" in hex

inline fn forwardKey(target_key: Hotkey.KeyPress, _: c.CGEventRef) !void {
    // Create a proper event source for the new event
    const event_source = c.CGEventSourceCreate(c.kCGEventSourceStateHIDSystemState);
    if (event_source == null) return error.FailedToCreateEventSource;
    defer c.CFRelease(event_source);

    // Create key down event
    const key_down = c.CGEventCreateKeyboardEvent(event_source, @intCast(target_key.key), true);
    if (key_down == null) return error.FailedToCreateKeyboardEvent;
    defer c.CFRelease(key_down);

    // Create key up event
    const key_up = c.CGEventCreateKeyboardEvent(event_source, @intCast(target_key.key), false);
    if (key_up == null) return error.FailedToCreateKeyboardEvent;
    defer c.CFRelease(key_up);

    // Set the modifier flags for both events
    const target_flags = hotkeyFlagsToCGEventFlags(target_key.flags);
    c.CGEventSetFlags(key_down, target_flags);
    c.CGEventSetFlags(key_up, target_flags);

    // Mark these events as generated by us to avoid processing them again
    c.CGEventSetIntegerValueField(key_down, c.kCGEventSourceUserData, SKHD_EVENT_MARKER);
    c.CGEventSetIntegerValueField(key_up, c.kCGEventSourceUserData, SKHD_EVENT_MARKER);

    // Post both key down and key up events
    c.CGEventPost(c.kCGSessionEventTap, key_down);
    c.CGEventPost(c.kCGSessionEventTap, key_up);
}

/// Compare hotkey flags, handling left/right modifier logic
/// config = hotkey from config file, keyboard = event from keyboard
pub inline fn hotkeyFlagsMatch(config: ModifierFlag, keyboard: ModifierFlag) bool {
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

inline fn hotkeyFlagsToCGEventFlags(hotkey_flags: ModifierFlag) c.CGEventFlags {
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

// Context for looking up hotkeys from keyboard events
// This uses our custom modifier matching logic
pub const KeyboardLookupContext = struct {
    pub fn hash(_: @This(), key: Hotkey.KeyPress) u32 {
        // Must match the hash function used by HotkeyMap for lookup to work
        return key.key;
    }

    pub fn eql(_: @This(), keyboard: Hotkey.KeyPress, config: *Hotkey, _: usize) bool {
        // Match keyboard event against config hotkey
        return config.key == keyboard.key and hotkeyFlagsMatch(config.flags, keyboard.flags);
    }
};

/// Find a hotkey in the mode that matches the keyboard event
/// Returns the hotkey pointer if found, null otherwise
pub inline fn findHotkeyInMode(self: *Skhd, mode: *const Mode, eventkey: Hotkey.KeyPress) ?*Hotkey {
    // Method 1: HashMap lookup with adapted context (O(1) average case)
    return self.findHotkeyHashMap(mode, eventkey);

    // Method 2: Linear array search (O(n) but potentially faster for small sets)
    // return self.findHotkeyLinear(mode, eventkey);
}

/// HashMap-based lookup using adapted context
pub inline fn findHotkeyHashMap(self: *Skhd, mode: *const Mode, eventkey: Hotkey.KeyPress) ?*Hotkey {
    self.tracer.traceHotkeyLookup();
    const ctx = KeyboardLookupContext{};
    const result = mode.hotkey_map.getKeyAdapted(eventkey, ctx);
    self.tracer.traceHotkeyFound(result != null);
    return result;
}

/// Linear search through all hotkeys in the mode
pub inline fn findHotkeyLinear(self: *Skhd, mode: *const Mode, eventkey: Hotkey.KeyPress) ?*Hotkey {
    self.tracer.traceHotkeyLookup();
    var it = mode.hotkey_map.iterator();
    var iterations: u64 = 0;
    while (it.next()) |entry| {
        iterations += 1;
        self.tracer.traceHotkeyComparison();
        const hotkey = entry.key_ptr.*;
        if (hotkey.key == eventkey.key and hotkeyFlagsMatch(hotkey.flags, eventkey.flags)) {
            self.tracer.traceLinearSearchIterations(iterations);
            self.tracer.traceHotkeyFound(true);
            return hotkey;
        }
    }
    self.tracer.traceLinearSearchIterations(iterations);
    self.tracer.traceHotkeyFound(false);
    return null;
}

/// Process a hotkey - single lookup that handles both forwarding and execution
inline fn processHotkey(self: *Skhd, eventkey: *const Hotkey.KeyPress, event: c.CGEventRef, process_name: []const u8) !bool {
    // Look up hotkey in current mode
    const mode = self.current_mode orelse return false;

    // Single lookup
    self.tracer.traceHotkeyLookup();
    const found_hotkey = self.findHotkeyInMode(mode, eventkey.*);

    if (found_hotkey == null) {
        self.tracer.traceHotkeyFound(false);
        return false;
    }

    self.tracer.traceHotkeyFound(true);
    const hotkey = found_hotkey.?;

    // Check for mode activation first
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

    // Check for process-specific command/forward
    if (findProcessInList(hotkey, process_name)) |proc_index| {
        if (proc_index < hotkey.commands.items.len) {
            switch (hotkey.commands.items[proc_index]) {
                .forwarded => |target_key| {
                    try self.logKeyPress("Forwarding key '{s}' for process '{s}'", target_key, process_name);
                    self.tracer.traceKeyForwarded();
                    try forwardKey(target_key, event);
                    return true;
                },
                .command => |cmd| {
                    self.logger.logDebug("Using process-specific command: '{s}'", .{cmd}) catch {};
                    self.tracer.traceCommandExecuted();
                    try self.executeCommand(self.mappings.shell, cmd);
                    return !hotkey.flags.passthrough;
                },
                .unbound => {
                    self.logger.logDebug("key is unbound for process '{s}'", .{process_name}) catch {};
                    return false;
                },
            }
        }
    }

    // Check wildcard command/forward
    if (hotkey.wildcard_command) |wildcard| {
        switch (wildcard) {
            .forwarded => |target_key| {
                try self.logKeyPress("Forwarding key '{s}' (wildcard), current process {s}", target_key, process_name);
                self.tracer.traceKeyForwarded();
                try forwardKey(target_key, event);
                return true;
            },
            .command => |cmd| {
                self.tracer.traceCommandExecuted();
                try self.executeCommand(self.mappings.shell, cmd);
                return !hotkey.flags.passthrough;
            },
            .unbound => return false,
        }
    }

    return false;
}


/// Fork and exec a command, detaching it from the parent process
inline fn forkAndExec(shell: []const u8, command: []const u8) !void {
    const cpid = c.fork();
    if (cpid == -1) {
        return error.ForkFailed;
    }

    if (cpid == 0) {
        // Child process
        // Create new session
        _ = c.setsid();

        // Prepare arguments for execvp
        // We need null-terminated strings
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const shell_z = try allocator.dupeZ(u8, shell);
        const arg_z = try allocator.dupeZ(u8, "-c");
        const command_z = try allocator.dupeZ(u8, command);

        const argv = [_:null]?[*:0]const u8{ shell_z, arg_z, command_z, null };

        const status_code = c.execvp(shell_z, @ptrCast(&argv));
        // If execvp returns, it failed
        std.process.exit(@intCast(status_code));
    }
    // Parent process returns immediately
}

inline fn executeCommand(self: *Skhd, shell: []const u8, command: []const u8) !void {
    // Log the command execution
    try self.logger.logInfo("Executing command: {s}", .{command});

    // In interactive mode, capture and display output
    if (self.logger.mode == .interactive) {
        const argv = [_][]const u8{ shell, "-c", command };

        var child = std.process.Child.init(&argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        // Read output synchronously to avoid race conditions
        self.readChildOutputSync(&child) catch {};
    } else {
        // In service mode, use fork and exec to detach the process
        try forkAndExec(shell, command);
    }
}

/// Find a process name in the hotkey's process list
/// Returns the index if found, null if not found
pub inline fn findProcessInList(hotkey: *const Hotkey, process_name: []const u8) ?usize {
    for (hotkey.process_names.items, 0..) |proc_name, i| {
        if (std.mem.eql(u8, proc_name, process_name)) {
            return i;
        }
    }
    return null;
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

/// Signal handler for SIGINT - print trace summary and exit
fn handleSigint(_: c_int) callconv(.C) void {
    if (global_skhd) |skhd| {
        if (skhd.tracer.enabled) {
            const stderr = std.io.getStdErr().writer();
            skhd.tracer.printSummary(stderr) catch {};
        }
    }
    std.process.exit(0);
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

    // Note: We don't re-enable hot reload here because this function
    // might be called from within the hotload callback. Instead, we'll
    // update the watched files list when hot reload is already enabled.

    try self.logger.logInfo("Configuration reloaded successfully", .{});
}

pub fn enableHotReload(self: *Skhd) !void {
    if (self.hotload_enabled) return;

    try self.logger.logInfo("Enabling hot reload...", .{});

    // Store self reference for callback
    global_skhd = self;

    // Create hotloader (already heap-allocated by create())
    const hotloader = try Hotload.create(self.allocator, hotloadCallback);

    // Resolve main config file to absolute path for FSEvents
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = try std.fs.cwd().realpath(self.config_file, &path_buf);

    try self.logger.logInfo("Watching main config: {s} (resolved to: {s})", .{ self.config_file, abs_path });
    try hotloader.addFile(abs_path);

    // Also watch all loaded files
    for (self.mappings.loaded_files.items) |loaded_file| {
        try self.logger.logInfo("Watching loaded file: {s}", .{loaded_file});
        hotloader.addFile(loaded_file) catch |err| {
            try self.logger.logInfo("Failed to watch loaded file {s}: {}", .{ loaded_file, err });
        };
    }

    // Start the hotloader
    try hotloader.start();

    self.hotloader = hotloader;
    self.hotload_enabled = true;

    try self.logger.logInfo("Hot reload enabled successfully", .{});
}

pub fn disableHotReload(self: *Skhd) void {
    if (!self.hotload_enabled) return;

    if (self.hotloader) |hotloader| {
        hotloader.destroy();
    }

    self.hotloader = null;
    self.hotload_enabled = false;

    self.logger.logInfo("Hot reload disabled", .{}) catch {};
}

fn hotloadCallback(path: []const u8) void {
    // Follow the original skhd approach - directly reload the config
    if (global_skhd) |skhd| {
        skhd.logger.logInfo("Config file has been modified: {s} .. reloading config", .{path}) catch {};
        skhd.reloadConfig() catch |err| {
            skhd.logger.logError("Failed to reload config: {}", .{err}) catch {};
        };
    } else {
        std.debug.print("ERROR: global_skhd is null in hotloadCallback\n", .{});
    }
}

/// Log a keypress with formatted key string
inline fn logKeyPress(self: *Skhd, comptime fmt: []const u8, key: Hotkey.KeyPress, process_name: []const u8) !void {
    // Only log in interactive mode to avoid allocation in hot path
    if (self.logger.mode != .interactive) return;

    const key_str = try Keycodes.formatKeyPress(self.allocator, key.flags, key.key);
    defer self.allocator.free(key_str);
    self.logger.logDebug(fmt, .{ key_str, process_name }) catch {};
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
