const std = @import("std");
const builtin = @import("builtin");
const EventTap = @import("EventTap.zig");
const Mappings = @import("Mappings.zig");
const Parser = @import("Parser.zig");
const Hotkey = @import("Hotkey.zig");
const Mode = @import("Mode.zig");
const Keycodes = @import("Keycodes.zig");
const ModifierFlag = Keycodes.ModifierFlag;
// Use scoped logging for skhd module
const log = std.log.scoped(.skhd);
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
verbose: bool,
hotloader: ?*Hotload = null,
hotload_enabled: bool = false,
tracer: Tracer,
carbon_event: *CarbonEvent,

pub fn init(allocator: std.mem.Allocator, config_file: []const u8, verbose: bool, profile: bool) !Skhd {
    log.info("Initializing skhd with config: {s}", .{config_file});

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
                log.err("skhd: {}", .{parse_err});
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
    log.info("Loaded modes: {s}", .{modes_list.items});

    // Log shell configuration
    log.info("Using shell: {s}", .{mappings.shell});

    // Initialize Carbon event handler for app switching
    var carbon_event = try CarbonEvent.init(allocator);
    errdefer carbon_event.deinit();

    log.info("Initial process: {s}", .{carbon_event.process_name});

    // Create event tap with keyboard and system defined events
    const mask: u32 = (1 << c.kCGEventKeyDown) | (1 << c.NX_SYSDEFINED);

    return Skhd{
        .allocator = allocator,
        .mappings = mappings,
        .current_mode = current_mode,
        .event_tap = EventTap{ .mask = mask },
        .config_file = try allocator.dupe(u8, config_file),
        .verbose = verbose,
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
        log.err("Cannot stat config file {s}: {}", .{ self.config_file, err });
        return err;
    };

    if (stat.kind != .file) {
        log.err("Config file {s} is not a regular file", .{self.config_file});
        return error.InvalidConfigFile;
    }

    // Enable hot reload if requested (must be done before run loop starts)
    if (enable_hotload) {
        try self.enableHotReload();
    }

    // Set up event tap (but don't start run loop yet)
    log.info("Starting event tap", .{});
    self.event_tap.begin(keyHandler, self) catch |err| {
        if (err == error.AccessibilityPermissionDenied) {
            const allocated_path: ?[]u8 = std.fs.selfExePathAlloc(self.allocator) catch null;
            defer if (allocated_path) |path| self.allocator.free(path);
            const exe_path = allocated_path orelse "/opt/homebrew/bin/skhd";

            log.err(
                \\
                \\=====================================================
                \\ACCESSIBILITY PERMISSIONS REQUIRED
                \\=====================================================
                \\skhd requires accessibility permissions to function.
                \\
                \\Please grant accessibility permissions:
                \\1. Open System Settings → Privacy & Security → Accessibility
                \\2. Click the lock to make changes
                \\3. Add this binary: {s}
                \\4. Make sure it's enabled (checkbox checked)
                \\5. Restart skhd
                \\
                \\Troubleshooting:
                \\If skhd is already listed but still not working:
                \\- Remove the existing skhd entry
                \\- Stop the service: skhd --stop-service
                \\- Re-add skhd to the list - Or just restart the service to see the entry added
                \\- Enable the entry and run skhd --restart-service
                \\=====================================================
                \\
            , .{exe_path});
        }
        return err;
    };

    // Call NSApplicationLoad() like the original skhd
    c.NSApplicationLoad();

    // Always log successful event tap creation
    log.info("Event tap created successfully. skhd is now running.", .{});

    // Now start the run loop - this will handle both event tap and FSEvents
    c.CFRunLoopRun();

    // If we get here, the run loop has exited
    log.info("Run loop exited", .{});
}

fn keyHandler(proxy: c.CGEventTapProxy, typ: c.CGEventType, event: c.CGEventRef, user_info: ?*anyopaque) callconv(.c) c.CGEventRef {
    _ = proxy;

    const self = @as(*Skhd, @ptrCast(@alignCast(user_info)));
    self.tracer.traceKeyEvent();

    switch (typ) {
        c.kCGEventTapDisabledByTimeout, c.kCGEventTapDisabledByUserInput => {
            log.info("Restarting event-tap", .{});
            c.CGEventTapEnable(self.event_tap.handle, true);
            return event;
        },
        c.kCGEventKeyDown => {
            self.tracer.traceKeyDown();
            return self.handleKeyDown(event) catch |err| {
                log.err("Error handling key down: {}", .{err});
                return event;
            };
        },
        c.NX_SYSDEFINED => {
            self.tracer.traceSystemKey();
            return self.handleSystemKey(event) catch |err| {
                log.err("Error handling system key: {}", .{err});
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

    // Check if current mode has capture enabled
    if (self.current_mode) |mode| {
        if (mode.capture) {
            // Mode has capture enabled, consume all keypresses
            try self.logKeyPress("Capture mode consuming unmatched key: {s}, process name: {s}", eventkey, .{process_name});
            return @ptrFromInt(0);
        }
    }

    try self.logKeyPress("No matching hotkey found for key: {s}, process name: {s}", eventkey, .{process_name});
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
        if (try self.processHotkey(&eventkey, event, process_name)) {
            return @ptrFromInt(0);
        }

        // Check if current mode has capture enabled
        if (self.current_mode) |mode| {
            if (mode.capture) {
                // Mode has capture enabled, consume all system keypresses
                return @ptrFromInt(0);
            }
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
    const ctx = Hotkey.KeyboardLookupContext{};
    const result = mode.hotkey_map.getKeyAdapted(eventkey, ctx);
    self.tracer.traceHotkeyFound(result != null);
    return result;
}

/// /// Linear search through all hotkeys in the mode
/// pub inline fn findHotkeyLinear(self: *Skhd, mode: *const Mode, eventkey: Hotkey.KeyPress) ?*Hotkey {
///     self.tracer.traceHotkeyLookup();
///     var it = mode.hotkey_map.iterator();
///     var iterations: u64 = 0;
///     while (it.next()) |entry| {
///         iterations += 1;
///         self.tracer.traceHotkeyComparison();
///         const hotkey = entry.key_ptr.*;
///         if (hotkey.key == eventkey.key and hotkeyFlagsMatch(hotkey.flags, eventkey.flags)) {
///             self.tracer.traceLinearSearchIterations(iterations);
///             self.tracer.traceHotkeyFound(true);
///             return hotkey;
///         }
///     }
///     self.tracer.traceLinearSearchIterations(iterations);
///     self.tracer.traceHotkeyFound(false);
///     return null;
/// }
/// Process a hotkey - single lookup that handles both forwarding and execution
inline fn processHotkey(self: *Skhd, eventkey: *const Hotkey.KeyPress, event: c.CGEventRef, process_name: []const u8) !bool {
    const mode = self.current_mode orelse return false;

    self.tracer.traceHotkeyLookup();
    const found_hotkey = self.findHotkeyInMode(mode, eventkey.*);

    if (found_hotkey == null) {
        self.tracer.traceHotkeyFound(false);
        return false;
    }

    try self.logKeyPress("Found hotkey: '{s}' for process: '{s}' in mode '{s}'", eventkey.*, .{ process_name, mode.name });
    self.tracer.traceHotkeyFound(true);
    const hotkey = found_hotkey.?;

    // Check for mode activation first
    if (hotkey.flags.activate) {
        log.debug("Mode activation hotkey triggered", .{});
        // Get the mode name from the activation mapping (stored with ";" as process name)
        if (hotkey.find_command_for_process(";")) |cmd| {
            switch (cmd) {
                .command => |mode_name| {
                    log.debug("Attempting to switch to mode '{s}'", .{mode_name});
                    // Try to find the mode
                    const new_mode = self.mappings.mode_map.getPtr(mode_name);

                    if (new_mode) |target_mode| {
                        self.current_mode = target_mode;
                        log.info("Switched to mode '{s}'", .{target_mode.name});
                        // Execute mode command if exists
                        if (target_mode.command) |mode_cmd| {
                            try forkAndExec(self.mappings.shell, mode_cmd, self.verbose);
                        }
                        return true;
                    } else if (std.mem.eql(u8, mode_name, "default")) {
                        // Switching to default mode which should always exist
                        if (self.mappings.mode_map.getPtr("default")) |default_mode| {
                            self.current_mode = default_mode;
                            log.info("Switched to default mode", .{});
                            return true;
                        }
                    }

                    // If we get here, mode wasn't found but we should still consume the event
                    // since this is a mode activation hotkey
                    return true;
                },
                else => {
                    log.debug("Activate flag set but no command found", .{});
                },
            }
        } else {
            log.debug("Activate flag set but no activation mapping found", .{});
        }
        return false;
    }

    // Check for process-specific command/forward (includes wildcard fallback)
    if (hotkey.find_command_for_process(process_name)) |process_cmd| {
        switch (process_cmd) {
            .forwarded => |target_key| {
                try self.logKeyPress("Forwarding key '{s}' for process {s}", target_key, .{process_name});
                self.tracer.traceKeyForwarded();
                try forwardKey(target_key, event);
                return true;
            },
            .command => |cmd| {
                log.debug("Executing command '{s}' for process {s}", .{ cmd, process_name });
                self.tracer.traceCommandExecuted();
                try forkAndExec(self.mappings.shell, cmd, self.verbose);
                return !hotkey.flags.passthrough;
            },
            .unbound => {
                log.debug("Unbound key for process {s}", .{process_name});
                return false;
            },
        }
    }

    return false;
}

/// Fork and exec a command, detaching it from the parent process
///
/// This function uses the classic "double fork" technique to create a true daemon process
/// that is completely detached from the parent. This prevents:
/// 1. The child from becoming a zombie when it exits
/// 2. The child from being affected by terminal hangups
/// 3. Terminal output from child processes appearing in skhd's logs
///
/// References:
/// - W. Richard Stevens, "Advanced Programming in the UNIX Environment", Chapter 13: Daemon Processes
/// - Linux daemon(3) man page implementation
/// - systemd source code: src/basic/process-util.c
///
/// The double fork works as follows:
/// 1. First fork: Parent creates child1
/// 2. Child1 calls setsid() to become session leader in new session
/// 3. Second fork: Child1 creates child2
/// 4. Child1 exits immediately, child2 continues
/// 5. Parent waits for child1 to prevent zombie
/// 6. Child2 is now orphaned and adopted by init (PID 1)
/// 7. When child2 eventually exits, init automatically reaps it
inline fn forkAndExec(shell: []const u8, command: []const u8, verbose: bool) !void {
    const cpid = c.fork();
    if (cpid == -1) {
        return error.ForkFailed;
    }

    if (cpid == 0) {
        // Child process
        // Create new session (detach from controlling terminal)
        _ = c.setsid();

        // Double fork to ensure we can't reacquire a controlling terminal
        const cpid2 = c.fork();
        if (cpid2 == -1) {
            std.process.exit(1);
        }
        if (cpid2 > 0) {
            // First child exits
            std.process.exit(0);
        }

        // Second child continues
        if (!verbose) {
            const devnull = c.open("/dev/null", c.O_WRONLY);
            if (devnull != -1) {
                _ = c.dup2(devnull, 1); // stdout
                _ = c.dup2(devnull, 2); // stderr
                _ = c.close(devnull);
            }
        }

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

    // Parent waits for first child to exit
    // This prevents the first child from becoming a zombie and ensures
    // the double fork completes before we return. The wait is very brief
    // since child1 exits immediately after forking child2.
    var status: c_int = 0;
    _ = c.waitpid(cpid, &status, 0);
}

/// Signal handler for SIGUSR1 - reload configuration
fn handleSigusr1(_: c_int) callconv(.C) void {
    if (global_skhd) |skhd| {
        log.info("Received SIGUSR1, reloading configuration", .{});
        skhd.reloadConfig() catch |err| {
            log.err("Failed to reload config: {}", .{err});
        };
    }
}

/// Signal handler for SIGINT - stop the run loop to allow graceful shutdown
fn handleSigint(_: c_int) callconv(.C) void {
    // Stop the run loop to allow graceful shutdown with defer statements
    c.CFRunLoopStop(c.CFRunLoopGetCurrent());
}

/// Reload configuration from file
pub fn reloadConfig(self: *Skhd) !void {
    log.info("Reloading configuration from: {s}", .{self.config_file});

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
                log.err("skhd: {}", .{parse_err});
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

    log.info("Configuration reloaded successfully", .{});
}

pub fn enableHotReload(self: *Skhd) !void {
    if (self.hotload_enabled) return;

    log.info("Enabling hot reload...", .{});

    // Store self reference for callback
    global_skhd = self;

    // Create hotloader (already heap-allocated by create())
    const hotloader = try Hotload.create(self.allocator, hotloadCallback);

    // Resolve main config file to absolute path for FSEvents
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = try std.fs.cwd().realpath(self.config_file, &path_buf);

    log.info("Watching main config: {s} (resolved to: {s})", .{ self.config_file, abs_path });
    try hotloader.addFile(abs_path);

    // Also watch all loaded files
    for (self.mappings.loaded_files.items) |loaded_file| {
        log.info("Watching loaded file: {s}", .{loaded_file});
        hotloader.addFile(loaded_file) catch |err| {
            log.info("Failed to watch loaded file {s}: {}", .{ loaded_file, err });
        };
    }

    // Start the hotloader
    try hotloader.start();

    self.hotloader = hotloader;
    self.hotload_enabled = true;

    log.info("Hot reload enabled successfully", .{});
}

pub fn disableHotReload(self: *Skhd) void {
    if (!self.hotload_enabled) return;

    if (self.hotloader) |hotloader| {
        hotloader.destroy();
    }

    self.hotloader = null;
    self.hotload_enabled = false;

    log.info("Hot reload disabled", .{});
}

fn hotloadCallback(path: []const u8) void {
    // Follow the original skhd approach - directly reload the config
    if (global_skhd) |skhd| {
        log.info("Config file has been modified: {s} .. reloading config", .{path});
        skhd.reloadConfig() catch |err| {
            log.err("Failed to reload config: {}", .{err});
        };
    } else {
        std.debug.print("ERROR: global_skhd is null in hotloadCallback\n", .{});
    }
}

/// Log a keypress with formatted key string
inline fn logKeyPress(self: *Skhd, comptime fmt: []const u8, key: Hotkey.KeyPress, rest: anytype) !void {
    if (comptime builtin.mode != .Debug and builtin.mode != .ReleaseSafe) return;
    // Only log in interactive mode to avoid allocation in hot path
    if (!self.verbose) return;

    const key_str = try Keycodes.formatKeyPress(self.allocator, key.flags, key.key);
    defer self.allocator.free(key_str);
    log.debug(fmt, .{key_str} ++ rest);
}
