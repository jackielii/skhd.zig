const std = @import("std");
const builtin = @import("builtin");

const c = @import("c.zig");
const agent_grabber_client = @import("agent_grabber_client.zig");
const agent_layer_listener = @import("agent_layer_listener.zig");
const CarbonEvent = @import("CarbonEvent.zig");
const EventTap = @import("EventTap.zig");
const forkAndExec = @import("exec.zig").forkAndExec;
const grabber_protocol = @import("grabber_protocol");
const DeviceCheck = @import("DeviceCheck.zig");
const Hidutil = @import("Hidutil.zig");
const Hotkey = @import("Hotkey.zig");
const Hotload = @import("Hotload.zig");
const Keycodes = @import("Keycodes.zig");
const ModifierFlag = Keycodes.ModifierFlag;
const Mappings = @import("Mappings.zig");
const Mode = @import("Mode.zig");
const Parser = @import("Parser.zig");
const service = @import("service.zig");
const Tracer = @import("Tracer.zig");

// Use scoped logging for skhd module
const log = std.log.scoped(.skhd);
const Skhd = @This();

// Global reference for signal handler
var global_skhd: ?*Skhd = null;
var reload_requested: std.atomic.Value(bool) = .init(false);
var stop_requested: std.atomic.Value(bool) = .init(false);
var hotload_refresh_pending: std.atomic.Value(bool) = .init(false);

// Result of processing a hotkey
const HotkeyResult = enum {
    consumed, // Hotkey handled, consume the event
    passthrough, // Hotkey found but marked as passthrough/unbound
    not_found, // No matching hotkey
};

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
watchdog_timer: c.CFRunLoopTimerRef = null,
/// Persistent IPC connection to skhd-grabber (for layer-hold pushes).
/// null when there are no caps-class rules, or when we couldn't dial
/// the grabber. The Client owns the socket fd; Listener wraps it as a
/// CFRunLoop source. Both freed on deinit.
grabber_client: ?*agent_grabber_client.Client = null,
layer_listener: ?*agent_layer_listener.Listener = null,
/// Periodic retry timer for re-dialing the grabber after a
/// disconnect. Null while connected (or when no rules need
/// forwarding); created on disconnect, cancelled on successful
/// forward.
grabber_reconnect_timer: c.CFRunLoopTimerRef = null,
/// Per-device `hidutil` UserKeyMapping owner. Allocated only when the
/// config has at least one colon-form `.remap`. On deinit (graceful or
/// signal), restoreAll() clears the OS-level mapping so the keyboard
/// returns to default.
hidutil: ?*Hidutil = null,

pub fn init(gpa: std.mem.Allocator, config_file: []const u8, verbose: bool, profile: bool) !Skhd {
    log.info("Initializing skhd with config: {s}", .{config_file});

    var mappings = try Mappings.init(gpa);
    errdefer mappings.deinit();

    // Parse configuration file
    var parser = try Parser.init(gpa);
    defer parser.deinit();

    const content = try std.fs.cwd().readFileAlloc(gpa, config_file, 1 << 20); // 1MB max
    defer gpa.free(content);

    parser.parseWithPath(&mappings, content, config_file) catch |err| {
        if (parser.error_info) |parse_err| {
            log.err("skhd: {}", .{parse_err});
        }
        return err;
    };

    // Process any .load directives. Surface include-file parse
    // errors with their file:line, same as the top-level file.
    parser.processLoadDirectives(&mappings) catch |err| {
        if (parser.error_info) |parse_err| {
            log.err("skhd: {}", .{parse_err});
        }
        return err;
    };

    // Initialize with default mode if exists
    var current_mode: ?*Mode = null;
    if (mappings.mode_map.getPtr("default")) |default_mode| {
        current_mode = default_mode;
    }

    // Log loaded modes
    var mode_iter = mappings.mode_map.iterator();
    var modes_list = std.ArrayList(u8).init(gpa);
    defer modes_list.deinit();
    while (mode_iter.next()) |entry| {
        try modes_list.writer().print("'{s}' ", .{entry.key_ptr.*});
    }
    log.info("Loaded modes: {s}", .{modes_list.items});

    // Log shell configuration
    log.info("Using shell: {s}", .{mappings.shell});

    // Initialize Carbon event handler for app switching
    var carbon_event = try CarbonEvent.init(gpa);
    errdefer carbon_event.deinit();

    log.info("Initial process: {s}", .{carbon_event.getProcessName()});

    // Lazy-init Hidutil only if any colon-form `.remap` declarations
    // exist. Crash recovery runs first so a previous instance's stale
    // UserKeyMapping is cleared before we apply our own.
    var hidutil: ?*Hidutil = null;
    if (mappings.remaps.items.len > 0) {
        hidutil = Hidutil.init(gpa) catch |err| blk: {
            log.warn("Hidutil init failed: {s}. .remap colon-form ignored.", .{@errorName(err)});
            break :blk null;
        };
        if (hidutil) |h| {
            h.recoverFromCrash() catch |err| {
                log.warn("Hidutil crash recovery failed: {s}. Continuing.", .{@errorName(err)});
            };
            log.info("Hidutil initialized for {d} remap declaration(s)", .{mappings.remaps.items.len});
        }
    }
    errdefer if (hidutil) |h| h.deinit();

    // Create event tap with keyboard, system-defined, and mouse-down events.
    // Mouse-down is opt-in only via `mouse1`–`mouse5` bindings, but the tap
    // mask is set unconditionally — `processHotkey` returns `.not_found` for
    // un-bound mouse events and we pass them through, so an unused mask bit
    // costs only a couple of dispatches per click.
    const mask: u32 = (1 << c.kCGEventKeyDown) | (1 << c.NX_SYSDEFINED) //
    | (1 << c.kCGEventLeftMouseDown) //
    | (1 << c.kCGEventRightMouseDown) //
    | (1 << c.kCGEventOtherMouseDown);

    return Skhd{
        .allocator = gpa,
        .mappings = mappings,
        .current_mode = current_mode,
        .event_tap = EventTap{ .mask = mask },
        .config_file = try gpa.dupe(u8, config_file),
        .verbose = verbose,
        .tracer = Tracer.init(profile),
        .carbon_event = carbon_event,
        .hidutil = hidutil,
    };
}

pub fn deinit(self: *Skhd) void {
    // Print tracer summary before cleanup
    if (self.tracer.enabled) {
        const stderr = std.io.getStdErr().writer();
        self.tracer.printSummary(stderr) catch {};
    }

    // Clear hidutil UserKeyMapping FIRST so the user's keyboard isn't
    // left remapped if anything below errors. Idempotent — no-op when
    // applyRemaps was never called.
    if (self.hidutil) |h| {
        h.restoreAll();
        h.deinit();
        self.hidutil = null;
    }

    if (self.hotloader) |hotloader| {
        hotloader.destroy();
    }
    self.stopWatchdog();
    self.cancelGrabberReconnect();
    if (self.layer_listener) |ll| ll.deinit();
    if (self.grabber_client) |gc| {
        gc.close();
        self.allocator.destroy(gc);
    }
    self.carbon_event.deinit();
    self.event_tap.deinit();
    self.mappings.deinit();
    self.allocator.free(self.config_file);
}

/// Translate parsed `.remap { tap, hold, ... }` rules into the
/// IPC schema and push them to skhd-grabber. Looks up each rule's
/// device alias to attach the (vendor, product) match the grabber
/// uses for IOHIDManager. Layer-hold rules carry `hold_layer` set
/// to a mode name; HID-key holds carry `hold_usage` set instead.
///
/// If any rule is a layer rule, the agent keeps the IPC connection
/// open and registers a CFFileDescriptor source so the grabber can
/// push `mode_change` messages back when the layer hold commits or
/// releases. Otherwise the connection is closed after `bye`.
///
/// "Cannot reach grabber" is downgraded to a warning by the caller —
/// users without `skhd --install-grabber` still get the rest of
/// their config running.
/// Read NSGlobalDomain `com.apple.keyboard.fnState` (the "Use F1, F2 …
/// as standard function keys" toggle in System Settings → Keyboard).
/// false = bare F-row keys send media actions (Apple's default), true
/// = bare F-row keys send literal F<i>. Forwarded to the grabber so
/// its F-row translation policy matches the user's setting.
///
/// Read from the agent because the agent runs as the logged-in user;
/// the root grabber would otherwise need to attach to a per-uid
/// preference domain. Defaults to false (the OS default) on any
/// failure — a missing/unreadable pref is exactly what an unset toggle
/// looks like.
fn readFkeysAsStandardPref() bool {
    const key = c.CFStringCreateWithCString(
        c.kCFAllocatorDefault,
        "com.apple.keyboard.fnState",
        c.kCFStringEncodingUTF8,
    );
    if (key == null) return false;
    defer c.CFRelease(key);

    const value = c.CFPreferencesCopyAppValue(key, c.kCFPreferencesAnyApplication);
    if (value == null) return false;
    defer c.CFRelease(value);

    if (c.CFGetTypeID(value) != c.CFBooleanGetTypeID()) return false;
    return c.CFBooleanGetValue(@ptrCast(value)) != 0;
}

fn forwardTapholdsToGrabber(self: *Skhd) !void {
    if (self.mappings.tapholds.items.len == 0 and self.mappings.remaps.items.len == 0) return;

    // Build a presence cache keyed by device alias so we don't enumerate
    // HID twice for the same alias. A rule whose device isn't connected
    // is silently dropped — the grabber would log "matched 0 devices"
    // and the user-facing UX would be a "grabber not running" warning
    // on machines (e.g. a Mac Studio) that share the config but lack
    // the targeted built-in keyboard.
    var present = std.StringHashMap(bool).init(self.allocator);
    defer present.deinit();

    const aliasPresent = struct {
        fn check(
            mappings: *const Mappings,
            cache: *std.StringHashMap(bool),
            alias_name: []const u8,
        ) bool {
            if (cache.get(alias_name)) |v| return v;
            const alias = mappings.device_aliases.get(alias_name) orelse return false;
            const ok = DeviceCheck.isPresent(alias.vendor, alias.product);
            cache.put(alias_name, ok) catch {};
            return ok;
        }
    }.check;

    var rules = try std.ArrayList(grabber_protocol.Rule).initCapacity(self.allocator, self.mappings.tapholds.items.len);
    defer rules.deinit();
    var remaps = try std.ArrayList(grabber_protocol.Remap).initCapacity(self.allocator, self.mappings.remaps.items.len);
    defer remaps.deinit();

    var has_layer_rule = false;
    var skipped_absent: usize = 0;

    for (self.mappings.tapholds.items) |th| {
        const alias = self.mappings.device_aliases.get(th.device_alias) orelse {
            log.warn("taphold for src=0x{X:0>2}: device alias '{s}' not in alias map (skip)", .{ th.src_usage, th.device_alias });
            continue;
        };
        if (!aliasPresent(&self.mappings, &present, th.device_alias)) {
            skipped_absent += 1;
            continue;
        }
        if (th.hold_layer != null) has_layer_rule = true;
        try rules.append(.{
            .src_usage = th.src_usage,
            .tap_usage = th.tap_usage,
            .hold_usage = th.hold_usage,
            .hold_layer = th.hold_layer,
            .device = .{ .vendor = alias.vendor, .product = alias.product },
            .timeout_ms = th.timeout_ms,
            .permissive_hold = th.permissive_hold,
            .hold_on_other_key_press = th.hold_on_other_key_press,
            .retro_tap = th.retro_tap,
        });
    }

    for (self.mappings.remaps.items) |rm| {
        const alias = self.mappings.device_aliases.get(rm.device_alias) orelse {
            log.warn("remap for src=0x{X:0>2}: device alias '{s}' not in alias map (skip)", .{ rm.src_usage, rm.device_alias });
            continue;
        };
        if (!aliasPresent(&self.mappings, &present, rm.device_alias)) {
            skipped_absent += 1;
            continue;
        }
        try remaps.append(.{
            .src_usage = rm.src_usage,
            .dst_usage = rm.dst_usage,
            .device = .{ .vendor = alias.vendor, .product = alias.product },
        });
    }

    if (skipped_absent > 0) {
        log.info("skipped {d} grabber rule(s) — target device not connected", .{skipped_absent});
    }
    if (rules.items.len == 0 and remaps.items.len == 0) return;

    const fkeys_as_standard = readFkeysAsStandardPref();

    log.info(
        "forwarding {d} tap-hold rule(s) and {d} remap(s) to skhd-grabber at {s} (layer_listen={} fkeys_as_standard={})",
        .{ rules.items.len, remaps.items.len, grabber_protocol.default_socket_path, has_layer_rule, fkeys_as_standard },
    );

    const client = try self.allocator.create(agent_grabber_client.Client);
    errdefer self.allocator.destroy(client);
    client.* = try agent_grabber_client.Client.connect(self.allocator, grabber_protocol.default_socket_path);
    errdefer client.close();

    try client.hello();
    try client.applyRules(rules.items, remaps.items, fkeys_as_standard);

    // Always keep the connection open + watch it for EOS, regardless
    // of whether this config has layer rules. The grabber's per-
    // connection rule tracking relies on EOS detection to drop a
    // dead agent's rules; if we close immediately when there are no
    // layer rules, the grabber would assume we're alive forever and
    // never fall back when this agent dies.
    self.grabber_client = client;
    self.layer_listener = try agent_layer_listener.Listener.init(
        self.allocator,
        client.stream.handle,
        modeChangePushed,
        self,
    );
    self.layer_listener.?.on_disconnect = grabberDisconnected;
    self.layer_listener.?.on_disconnect_ctx = self;
    if (has_layer_rule) {
        log.info("grabber acknowledged {d} rule(s); layer listener installed", .{rules.items.len});
    } else {
        log.info("grabber acknowledged {d} rule(s); listener active for EOS", .{rules.items.len});
    }
    // Successful forward: cancel any pending reconnect timer from a
    // prior outage.
    self.cancelGrabberReconnect();
}

/// Run-loop callback fired by `agent_layer_listener` whenever the
/// grabber pushes a mode_change. Empty `mode_name` means "exit current
/// layer back to default".
fn modeChangePushed(ctx: ?*anyopaque, mode_name: []const u8) void {
    const self: *Skhd = @ptrCast(@alignCast(ctx orelse return));
    if (mode_name.len == 0) {
        if (self.mappings.mode_map.getPtr("default")) |m| {
            self.current_mode = m;
            log.info("layer push: exited to default", .{});
        } else {
            self.current_mode = null;
        }
        return;
    }
    if (self.mappings.mode_map.getPtr(mode_name)) |m| {
        self.current_mode = m;
        log.info("layer push: entered '{s}'", .{mode_name});
    } else {
        log.warn("layer push: unknown mode '{s}'", .{mode_name});
    }
}

/// Poll AXIsProcessTrusted on a 1s timer and reconcile the event tap with
/// what TCC currently allows. The OS doesn't fire kCGEventTapDisabledBy*
/// when accessibility is revoked at runtime, so the disabled-branch alone
/// can't catch a revoke — the tap stays in the event chain as an active
/// filter that swallows keystrokes. This watchdog is the only reliable
/// signal: detect revoke and tear the tap down, detect re-grant and
/// recreate it. AXIsProcessTrusted is cached and ~µs, so 1s polling is
/// negligible overhead and never touches the per-event hot path.
fn startWatchdog(self: *Skhd) void {
    if (self.watchdog_timer != null) return;
    var ctx = c.CFRunLoopTimerContext{
        .version = 0,
        .info = self,
        .retain = null,
        .release = null,
        .copyDescription = null,
    };
    const interval: f64 = 1.0;
    const fire_at = c.CFAbsoluteTimeGetCurrent() + interval;
    self.watchdog_timer = c.CFRunLoopTimerCreate(
        c.kCFAllocatorDefault,
        fire_at,
        interval,
        0,
        0,
        watchdogCallback,
        &ctx,
    );
    if (self.watchdog_timer == null) {
        log.err("Failed to create accessibility watchdog timer", .{});
        return;
    }
    c.CFRunLoopAddTimer(c.CFRunLoopGetMain(), self.watchdog_timer, c.kCFRunLoopCommonModes);
}

fn stopWatchdog(self: *Skhd) void {
    if (self.watchdog_timer) |t| {
        c.CFRunLoopTimerInvalidate(t);
        c.CFRelease(t);
        self.watchdog_timer = null;
    }
}

/// Listener-side disconnect callback. Tear down the dead client +
/// listener so the next reconnect attempt starts clean, then schedule
/// a retry timer.
fn grabberDisconnected(ctx: ?*anyopaque) void {
    const self = @as(*Skhd, @ptrCast(@alignCast(ctx orelse return)));
    if (self.layer_listener) |ll| {
        ll.deinit();
        self.layer_listener = null;
    }
    if (self.grabber_client) |gc| {
        gc.close();
        self.allocator.destroy(gc);
        self.grabber_client = null;
    }
    self.scheduleGrabberReconnect();
}

fn scheduleGrabberReconnect(self: *Skhd) void {
    if (self.grabber_reconnect_timer != null) return;
    var ctx = c.CFRunLoopTimerContext{
        .version = 0,
        .info = self,
        .retain = null,
        .release = null,
        .copyDescription = null,
    };
    // 2-second cadence — grabber respawn under launchd is typically
    // <1s, manual restart (`zig build run-grabber` Ctrl+C cycle)
    // a few seconds. Repeats until forward succeeds.
    const interval: f64 = 2.0;
    const fire_at = c.CFAbsoluteTimeGetCurrent() + interval;
    self.grabber_reconnect_timer = c.CFRunLoopTimerCreate(
        c.kCFAllocatorDefault,
        fire_at,
        interval,
        0,
        0,
        grabberReconnectCallback,
        &ctx,
    );
    if (self.grabber_reconnect_timer == null) {
        log.warn("could not create grabber reconnect timer; rules will only be forwarded on next reload", .{});
        return;
    }
    c.CFRunLoopAddTimer(c.CFRunLoopGetMain(), self.grabber_reconnect_timer, c.kCFRunLoopCommonModes);
    log.info("grabber connection lost — retrying every {d}s", .{@as(u32, @intFromFloat(interval))});
}

fn cancelGrabberReconnect(self: *Skhd) void {
    if (self.grabber_reconnect_timer) |t| {
        c.CFRunLoopTimerInvalidate(t);
        c.CFRelease(t);
        self.grabber_reconnect_timer = null;
    }
}

fn grabberReconnectCallback(_: c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const self = @as(*Skhd, @ptrCast(@alignCast(info orelse return)));
    self.forwardTapholdsToGrabber() catch {
        // Forward failed (likely "socket not found" or
        // "connection refused"). Timer stays armed, will fire again.
        return;
    };
    // forwardTaphold... already calls cancelGrabberReconnect on success.
}

fn watchdogCallback(_: c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const self = @as(*Skhd, @ptrCast(@alignCast(info)));

    if (stop_requested.swap(false, .acq_rel)) {
        log.info("Received stop request, stopping run loop", .{});
        c.CFRunLoopStop(c.CFRunLoopGetCurrent());
        return;
    }

    if (reload_requested.swap(false, .acq_rel)) {
        log.info("Received SIGUSR1, reloading configuration", .{});
        self.reloadConfig() catch |err| {
            log.err("Failed to reload config: {}", .{err});
        };
    }
    self.processPendingHotReloadRefresh();

    const trusted = service.hasAccessibilityPermissions();
    const have_tap = self.event_tap.handle != null;

    if (!trusted and have_tap) {
        log.err("Accessibility revoked — detaching event tap so the keyboard stays responsive.", .{});
        self.event_tap.deinit();
        if (self.event_tap.handle != null) {
            log.err("Event tap detach left handle non-null; keyboard may still be captured.", .{});
        } else {
            log.info("Event tap detached. Watchdog will recreate it when accessibility is re-granted.", .{});
        }
        return;
    }
    if (trusted and !have_tap) {
        log.info("Accessibility re-granted — recreating event tap.", .{});
        self.event_tap.begin(keyHandler, self) catch |err| {
            log.err("Failed to recreate event tap after re-grant: {} — will retry on next watchdog tick.", .{err});
            return;
        };
        log.info("Event tap reactivated. Hotkeys restored.", .{});
    }
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

    // Now that we hold a stable address for `self`, dial skhd-grabber
    // and forward any caps-class rules. We defer this from init() to
    // here so:
    //  (1) the layer listener can use `self` as its callback context,
    //  (2) the listener registers on the same CFRunLoop the event
    //      tap is about to attach to.
    //
    // Propagate the error: forwardTapholdsToGrabber returns early when
    // the config has no caps-class rules (or none whose target devices
    // are connected), so an error here means the config genuinely needs
    // the grabber and we couldn't reach it. Better to exit and let
    // launchd respawn us — by then the grabber daemon should be up —
    // than silently run with the caps-class rules disabled.
    self.forwardTapholdsToGrabber() catch |err| {
        log.err("config requires skhd-grabber but forward failed: {s} — exiting so launchd can retry", .{@errorName(err)});
        return err;
    };

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

    // Set up event tap (but don't start run loop yet). Only ask the OS to
    // show the Accessibility prompt when running as a launchd-managed daemon
    // (SMAppService). Foreground runs (`zig build run`, `zig build alloc
    // -- -V`, etc.) just check silently — popping a system dialog every
    // time you iterate on a debug build is noise, and Tahoe's TCC
    // mis-displays the path anyway when self-signed dev/prod bundles share
    // a `com.jackielii.skhd*` identifier prefix.
    const main = @import("main.zig");
    const is_daemon = main.isLaunchdManaged();
    const trusted = if (is_daemon)
        service.promptForAccessibility()
    else
        service.hasAccessibilityPermissions();
    if (!trusted) {
        log.warn("Accessibility not granted for this bundle. {s}", .{
            if (is_daemon)
                "System Settings should now show the prompt."
            else
                "Foreground run — grant manually in System Settings → Privacy & Security → Accessibility, or run the daemon (install-local) to get the prompt.",
        });
    }
    // Note: Input Monitoring prompt deliberately NOT triggered here.
    // IOHIDRequestAccess blocks the calling thread until the user clicks
    // Allow/Deny ("The user response is required before this function
    // returns" — Apple docs). Calling it from agent startup hangs the
    // daemon's main thread, which in turn hangs `launchctl bootstrap`
    // (and thus `zig build install-local`). The IM prompt fires from the
    // interactive `--install-service` flow instead, where the user is at
    // a terminal and expects dialogs.
    log.info("Starting event tap", .{});
    self.event_tap.begin(keyHandler, self) catch |err| {
        if (err == error.AccessibilityPermissionDenied) {
            const raw_path: ?[]u8 = std.fs.selfExePathAlloc(self.allocator) catch null;
            defer if (raw_path) |p| self.allocator.free(p);
            const stable_path: ?[]const u8 = if (raw_path) |p|
                service.resolveStableExePath(self.allocator, p) catch null
            else
                null;
            defer if (stable_path) |p| self.allocator.free(p);
            const bundle_path: ?[]const u8 = if (stable_path) |p|
                service.resolveBundlePath(self.allocator, p) catch null
            else
                null;
            defer if (bundle_path) |p| self.allocator.free(p);
            const display_path = bundle_path orelse stable_path orelse raw_path orelse "/Applications/skhd.app";

            log.err(
                \\
                \\=====================================================
                \\ACCESSIBILITY PERMISSIONS REQUIRED
                \\=====================================================
                \\skhd needs accessibility permissions to capture hotkeys.
                \\
                \\1. Open System Settings → Privacy & Security → Accessibility
                \\2. Click '+' and add: {s}
                \\3. Toggle the entry on
                \\4. Run: skhd --restart-service
                \\
                \\Troubleshooting:
                \\- macOS Tahoe hides bare-binary entries from the Accessibility
                \\  list. If the path above is not a .app, install the app
                \\  bundle (`brew upgrade skhd-zig`) so the entry is visible
                \\  and toggleable, then re-run --install-service.
                \\- If skhd was working before and stopped after a `brew
                \\  upgrade` (or any binary swap), the TCC entry likely shows
                \\  as granted but its csreq is anchored to the previous
                \\  cdHash. Reset and re-grant:
                \\    tccutil reset ListenEvent com.jackielii.skhd
                \\    tccutil reset Accessibility com.jackielii.skhd
                \\    skhd --restart-service   # then re-grant in Settings
                \\  See docs/CODE_SIGNING.md for the full troubleshooting
                \\  section.
                \\=====================================================
                \\
            , .{display_path});
        }
        return err;
    };

    // Call NSApplicationLoad() like the original skhd
    c.NSApplicationLoad();

    log.info("Event tap created successfully. skhd is now running.", .{});

    // Apply hidutil remaps AFTER the event tap is up — the OS starts
    // delivering remapped keys immediately, and we want our tap
    // intercepting the translated stream.
    if (self.hidutil) |h| {
        h.applyRemaps(&self.mappings) catch |err| {
            log.err("Failed to apply hidutil remaps: {s}. Colon-form .remap rules will not take effect.", .{@errorName(err)});
        };
    }

    // Watchdog reconciles the tap with TCC state every 1s. Catches runtime
    // accessibility revoke (which the OS doesn't surface via the disabled
    // callback) and re-grant.
    self.startWatchdog();

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
            // Legitimate timeout / user-input throttle: re-enable. Runtime
            // accessibility revoke does not reach this branch (the OS stops
            // delivering callbacks instead of sending the disabled event) —
            // the watchdog timer catches that case.
            log.info("Restarting event-tap (typ={d})", .{typ});
            c.CGEventTapEnable(self.event_tap.handle, true);
            if (!c.CGEventTapIsEnabled(self.event_tap.handle)) {
                log.err("CGEventTapEnable did not bring the tap back; watchdog will detach it on the next tick.", .{});
            }
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
        c.kCGEventLeftMouseDown => return self.handleMouseDown(event, 1) catch |err| {
            log.err("Error handling mouse down: {}", .{err});
            return event;
        },
        c.kCGEventRightMouseDown => return self.handleMouseDown(event, 2) catch |err| {
            log.err("Error handling mouse down: {}", .{err});
            return event;
        },
        c.kCGEventOtherMouseDown => {
            // CGMouseEventButtonNumber is 0-based: 0=left, 1=right, 2=middle,
            // 3=back, 4=forward. Left/right come through their own event
            // types, so here we expect button >= 2 → mouse3..mouse5+.
            const btn_raw = c.CGEventGetIntegerValueField(event, c.kCGMouseEventButtonNumber);
            if (btn_raw < 2 or btn_raw > 4) return event;
            const mouse_n: u8 = @intCast(btn_raw + 1);
            return self.handleMouseDown(event, mouse_n) catch |err| {
                log.err("Error handling mouse down: {}", .{err});
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

    const eventkey = createEventKey(event);
    const result = try self.processHotkey(&eventkey, event, process_name);
    return try self.handleHotkeyResult(result, event, eventkey, process_name);
}

inline fn handleMouseDown(self: *Skhd, event: c.CGEventRef, mouse_n: u8) !c.CGEventRef {
    if (self.current_mode == null) return event;

    // Skip self-generated events.
    const marker = c.CGEventGetIntegerValueField(event, c.kCGEventSourceUserData);
    if (marker == SKHD_EVENT_MARKER) return event;

    const process_name = self.carbon_event.getProcessName();
    if (self.mappings.blacklist.contains(process_name)) return event;

    const eventkey = Hotkey.KeyPress{
        .key = Keycodes.mouseButtonCode(mouse_n),
        .flags = cgeventFlagsToHotkeyFlags(c.CGEventGetFlags(event)),
    };
    const result = try self.processHotkey(&eventkey, event, process_name);
    return try self.handleHotkeyResult(result, event, eventkey, process_name);
}

/// Process the result of a hotkey lookup and determine what to do with the event
inline fn handleHotkeyResult(self: *Skhd, result: HotkeyResult, event: c.CGEventRef, eventkey: Hotkey.KeyPress, process_name: []const u8) !c.CGEventRef {
    switch (result) {
        .consumed => return @ptrFromInt(0),
        .passthrough => return event,
        .not_found => {
            // Check if current mode has capture enabled
            if (self.current_mode) |mode| {
                if (mode.capture) {
                    // Mode has capture enabled, consume all unmatched keypresses
                    try self.logKeyPress("Capture mode consuming unmatched key: {s}, process name: {s}", eventkey, .{process_name});
                    return @ptrFromInt(0);
                }
            }

            try self.logKeyPress("No matching hotkey found for key: {s}, process name: {s}", eventkey, .{process_name});
            return event;
        },
    }
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
        const result = try self.processHotkey(&eventkey, event, process_name);
        return try self.handleHotkeyResult(result, event, eventkey, process_name);
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
    // Mouse buttons live in a separate keycode space (≥ 0x10000) and need
    // CGEventCreateMouseEvent rather than CGEventCreateKeyboardEvent.
    if (Keycodes.isMouseButton(target_key.key)) {
        try postMouseClick(target_key);
        return;
    }
    // Check if this is an NX media key (requires different event type)
    if (target_key.flags.nx) {
        try postMediaKeyEvent(target_key.key);
        return;
    }

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

/// Synthesize a mouse-down + mouse-up at the current cursor position.
/// Used for `... | mouse1` forwards. The cursor doesn't move; we just
/// fire a click in place.
inline fn postMouseClick(target_key: Hotkey.KeyPress) !void {
    const button: u32 = target_key.key & 0xFF; // 1..5
    const down_type: c.CGEventType, const up_type: c.CGEventType, const cg_button: c.CGMouseButton = switch (button) {
        1 => .{ c.kCGEventLeftMouseDown, c.kCGEventLeftMouseUp, c.kCGMouseButtonLeft },
        2 => .{ c.kCGEventRightMouseDown, c.kCGEventRightMouseUp, c.kCGMouseButtonRight },
        else => .{ c.kCGEventOtherMouseDown, c.kCGEventOtherMouseUp, @intCast(button - 1) },
    };

    // CGEventCreate(NULL) returns an empty event whose location field is
    // populated with the current cursor position — cheaper than a Cocoa
    // round-trip via NSEvent.mouseLocation.
    const probe = c.CGEventCreate(null);
    if (probe == null) return error.FailedToProbeMouse;
    defer c.CFRelease(probe);
    const cursor = c.CGEventGetLocation(probe);

    const source = c.CGEventSourceCreate(c.kCGEventSourceStateHIDSystemState);
    if (source == null) return error.FailedToCreateEventSource;
    defer c.CFRelease(source);

    const down = c.CGEventCreateMouseEvent(source, down_type, cursor, cg_button);
    if (down == null) return error.FailedToCreateMouseEvent;
    defer c.CFRelease(down);

    const up = c.CGEventCreateMouseEvent(source, up_type, cursor, cg_button);
    if (up == null) return error.FailedToCreateMouseEvent;
    defer c.CFRelease(up);

    // Carry any modifier flags from the forward target so syntax like
    // `key | cmd - mouse1` synthesizes a cmd-click rather than a plain click.
    const target_flags = hotkeyFlagsToCGEventFlags(target_key.flags);
    c.CGEventSetFlags(down, target_flags);
    c.CGEventSetFlags(up, target_flags);

    // Mark as self-generated so handleMouseDown re-entry skips them.
    c.CGEventSetIntegerValueField(down, c.kCGEventSourceUserData, SKHD_EVENT_MARKER);
    c.CGEventSetIntegerValueField(up, c.kCGEventSourceUserData, SKHD_EVENT_MARKER);

    c.CGEventPost(c.kCGSessionEventTap, down);
    c.CGEventPost(c.kCGSessionEventTap, up);
}

/// Synthesize and post a media key event (play, next, previous, etc.)
/// Media keys use NX_SYSDEFINED events with special data encoding, not regular keyboard events.
/// Reference: https://stackoverflow.com/questions/11045814/emulate-media-key-press-on-mac
inline fn postMediaKeyEvent(key_code: u32) !void {
    try postMediaKeyPress(key_code, true); // key down
    try postMediaKeyPress(key_code, false); // key up
}

/// Post a single media key press (down or up) using NSEvent.otherEvent
/// The data1 field encodes: (key_code << 16) | (state_flags << 8)
/// where state_flags is 0x0a for down, 0x0b for up
fn postMediaKeyPress(key_code: u32, key_down: bool) !void {
    const NSEventClass = c.objc_getClass("NSEvent");
    if (NSEventClass == null) return error.FailedToGetNSEventClass;

    const state_flags: c_long = if (key_down) 0x0a00 else 0x0b00;
    const data1: c_long = (@as(c_long, @intCast(key_code)) << 16) | state_flags;

    const ev = nsEventOtherEvent(
        @ptrCast(@alignCast(NSEventClass)),
        14, // NSEventTypeSystemDefined
        8, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
        data1,
    );

    if (ev != null) {
        const cg_event = nsEventToCGEvent(ev);
        if (cg_event != null) {
            c.CGEventPost(c.kCGHIDEventTap, cg_event);
        }
    }
}

/// Create an NSEvent using otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:
/// Reference: https://stackoverflow.com/questions/11045814/emulate-media-key-press-on-mac
fn nsEventOtherEvent(ns_event_class: c.id, event_type: c_ulong, subtype: c_short, data1: c_long) c.id {
    const sel = c.sel_registerName("otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:");
    const msgSend = @extern(*const fn (
        c.id,
        c.SEL,
        c_ulong,
        f64,
        f64,
        c_ulong,
        f64,
        c_long,
        ?*anyopaque,
        c_short,
        c_long,
        c_long,
    ) callconv(.C) c.id, .{ .name = "objc_msgSend" });

    return msgSend(
        ns_event_class,
        sel,
        event_type,
        0.0,
        0.0, // location
        @as(c_ulong, @bitCast(data1)) & 0xff00, // modifierFlags from data1
        0.0, // timestamp
        0, // windowNumber
        null, // context
        subtype,
        data1,
        -1, // data2
    );
}

/// Get CGEvent from NSEvent by calling [event CGEvent]
fn nsEventToCGEvent(ns_event: c.id) c.CGEventRef {
    const sel = c.sel_registerName("CGEvent");
    const msgSend = @extern(*const fn (c.id, c.SEL) callconv(.C) ?*anyopaque, .{ .name = "objc_msgSend" });
    return @ptrCast(msgSend(ns_event, sel));
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

/// Wildcard fallback for capture (layer) modes: same key, but the
/// lookup ignores the keyboard's modifiers and only matches a config
/// hotkey that itself was declared without explicit modifiers. Used
/// to get QMK-style layer transparency: `fn_layer < h | left` should
/// also fire for `shift+h`, `ctrl+h`, etc., with the user's actual
/// modifiers carried through to the forwarded keystroke.
pub inline fn findWildcardHotkey(_: *Skhd, mode: *const Mode, eventkey: Hotkey.KeyPress) ?*Hotkey {
    const ctx = Hotkey.WildcardLookupContext{};
    return mode.hotkey_map.getKeyAdapted(eventkey, ctx);
}

/// Process a hotkey - single lookup that handles both forwarding and execution
inline fn processHotkey(self: *Skhd, eventkey: *const Hotkey.KeyPress, event: c.CGEventRef, process_name: []const u8) !HotkeyResult {
    const mode = self.current_mode orelse return .not_found;

    self.tracer.traceHotkeyLookup();
    var found_hotkey = self.findHotkeyInMode(mode, eventkey.*);

    // Capture-mode layer transparency: if no exact-modifier match
    // exists, try the wildcard lookup (matches the same key code
    // against any rule with no declared modifiers). When this hits,
    // we OR the user's actual modifiers into the forwarded output
    // below so e.g. `fn_layer < h | left` also handles `lctrl+h`
    // → `lctrl+left`.
    var via_wildcard = false;
    if (found_hotkey == null and mode.capture) {
        found_hotkey = self.findWildcardHotkey(mode, eventkey.*);
        via_wildcard = (found_hotkey != null);
    }

    if (found_hotkey == null) {
        self.tracer.traceHotkeyFound(false);
        return .not_found;
    }

    // Format the matched hotkey to mirror the config-file syntax —
    // `mode < key` so the log line reads the same way the binding
    // is written. Default mode prints just the key (no `default <`
    // prefix in user configs). Compile out entirely in release
    // builds (log.debug is filtered there anyway).
    if (comptime builtin.mode == .Debug) {
        if (self.verbose) {
            var key_buf: [256]u8 = undefined;
            const key_str = try Keycodes.formatKeyPressBuffer(&key_buf, eventkey.flags, eventkey.key);
            if (std.mem.eql(u8, mode.name, "default")) {
                log.debug("Found hotkey: '{s}' for process: '{s}'", .{ key_str, process_name });
            } else {
                log.debug("Found hotkey: '{s} < {s}' for process: '{s}'", .{ mode.name, key_str, process_name });
            }
        }
    }
    self.tracer.traceHotkeyFound(true);
    const hotkey = found_hotkey.?;

    // Check for process-specific command/forward (includes wildcard fallback)
    if (hotkey.find_command_for_process(process_name)) |process_cmd| {
        switch (process_cmd) {
            .forwarded => |target_key| {
                // QMK-style layer transparency: when a wildcard
                // (no-modifier) layer rule fires, OR the user's
                // actual modifiers into the forward target so
                // shift+h → shift+left, ctrl+h → ctrl+left, etc.
                // Without the wildcard match (i.e. an explicit
                // modifier rule fired), use the rule's target as-is.
                const effective_target: Hotkey.KeyPress = if (via_wildcard) .{
                    .flags = target_key.flags.merge(eventkey.flags),
                    .key = target_key.key,
                } else target_key;
                try self.logKeyPress("Forwarding key '{s}' for process {s}", effective_target, .{process_name});
                self.tracer.traceKeyForwarded();
                try forwardKey(effective_target, event);
                return .consumed;
            },
            .command => |cmd| {
                log.debug("Executing command '{s}' for process {s}", .{ cmd, process_name });
                self.tracer.traceCommandExecuted();
                try forkAndExec(self.mappings.shell, cmd, self.verbose);
                return if (hotkey.flags.passthrough) .passthrough else .consumed;
            },
            .unbound => {
                log.debug("Unbound key for process {s}", .{process_name});
                return .passthrough;
            },
            .activation => |act| {
                // Execute activation command if provided
                if (act.command) |activation_cmd| {
                    log.debug("Executing activation command: {s}", .{activation_cmd});
                    try forkAndExec(self.mappings.shell, activation_cmd, self.verbose);
                }
                log.debug("Activating mode '{s}'", .{act.mode_name});
                self.current_mode = self.mappings.mode_map.getPtr(act.mode_name);
                if (self.current_mode) |_mode| {
                    if (_mode.command) |mode_cmd| {
                        log.debug("Executing mode command: {s}", .{mode_cmd});
                        try forkAndExec(self.mappings.shell, mode_cmd, self.verbose);
                    }
                } else {
                    log.err("Failed to activate mode '{s}': mode not found", .{act.mode_name});
                    log.debug("Resetting to default mode", .{});
                    self.current_mode = self.mappings.mode_map.getPtr("default");
                }

                return .consumed;
            },
        }
    }

    return .not_found;
}

/// Signal handler for SIGUSR1 - reload configuration
fn handleSigusr1(_: c_int) callconv(.C) void {
    reload_requested.store(true, .release);
}

/// Signal handler for SIGINT - stop the run loop to allow graceful shutdown
fn handleSigint(_: c_int) callconv(.C) void {
    stop_requested.store(true, .release);
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
        // Log the parse error with proper formatting
        if (parser.error_info) |parse_err| {
            log.err("skhd: {}", .{parse_err});
        }
        return err;
    };
    parser.processLoadDirectives(&new_mappings) catch |err| {
        if (parser.error_info) |parse_err| {
            log.err("skhd: {}", .{parse_err});
        }
        return err;
    };

    // Swap old mappings with new ones
    self.mappings.deinit();
    self.mappings = new_mappings;

    // Reset to default mode
    if (self.mappings.mode_map.getPtr("default")) |default_mode| {
        self.current_mode = default_mode;
    } else {
        self.current_mode = null;
    }

    // Re-apply hidutil for any colon-form `.remap` rules in the new
    // config. Without this, edits to .remap directives wouldn't take
    // effect on hot reload — the OS-level UserKeyMapping would still
    // reflect the previous parse. Lazy-init the Hidutil owner if the
    // previous config had no remaps but the new one does.
    if (self.hidutil == null and self.mappings.remaps.items.len > 0) {
        self.hidutil = Hidutil.init(self.allocator) catch |err| blk: {
            log.warn("Hidutil init on reload failed: {s}. .remap colon-form ignored.", .{@errorName(err)});
            break :blk null;
        };
    }
    if (self.hidutil) |h| {
        // Clear whatever's installed before re-applying; this also
        // covers the case where the new config removed every remap
        // (then we just clear and stay quiescent).
        h.restoreAll();
        if (self.mappings.remaps.items.len > 0) {
            h.applyRemaps(&self.mappings) catch |err| {
                log.err("Failed to re-apply hidutil remaps on reload: {s}", .{@errorName(err)});
            };
        }
    }

    // Tear down the previous grabber connection so forwardTapholds...
    // can dial fresh with the updated rules. Do this even when the
    // new config has no caps-class rules — closing the old socket
    // is how the grabber learns we don't want our previous rules
    // applied any more.
    //
    // No `bye` here: once apply_rules has succeeded, the grabber moves
    // this socket out of `Ipc.serve` and into its subscriptionCallback,
    // which only PEEKs for EOS and discards any frame the agent writes
    // as "stray bytes". A bye on a subscription connection therefore
    // never gets a reply — and worse, an `expectOk` read after it can
    // pick up a queued `mode_change` push (logged as "unexpected type:
    // mode_change") or block indefinitely. EOS-on-close is the only
    // teardown signal the subscription path actually honors.
    if (self.layer_listener) |ll| {
        ll.deinit();
        self.layer_listener = null;
    }
    if (self.grabber_client) |gc| {
        gc.close();
        self.allocator.destroy(gc);
        self.grabber_client = null;
    }
    self.forwardTapholdsToGrabber() catch |err| {
        log.warn("hot reload: could not forward updated rules to skhd-grabber: {s}", .{@errorName(err)});
    };

    self.requestHotReloadRefresh();

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

fn refreshHotReload(self: *Skhd) !void {
    if (!self.hotload_enabled) return;
    if (self.hotloader) |hotloader| {
        hotloader.destroy();
    }
    self.hotloader = null;
    self.hotload_enabled = false;
    try self.enableHotReload();
}

fn requestHotReloadRefresh(self: *Skhd) void {
    if (!self.hotload_enabled) return;
    hotload_refresh_pending.store(true, .release);
}

fn processPendingHotReloadRefresh(self: *Skhd) void {
    if (!hotload_refresh_pending.swap(false, .acq_rel)) return;
    self.refreshHotReload() catch |err| {
        log.warn("hot reload: failed to refresh watched files after reload: {s}", .{@errorName(err)});
    };
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

/// Log a keypress with formatted key string. Compile out in any
/// non-Debug build — log.debug is filtered above ReleaseSafe and
/// even ReleaseSafe sets `log_level = .info`, so the format work
/// would be wasted there.
inline fn logKeyPress(self: *Skhd, comptime fmt: []const u8, key: Hotkey.KeyPress, rest: anytype) !void {
    if (comptime builtin.mode != .Debug) return;
    if (!self.verbose) return;

    var buf: [256]u8 = undefined;
    const key_str = try Keycodes.formatKeyPressBuffer(&buf, key.flags, key.key);
    log.debug(fmt, .{key_str} ++ rest);
}

// Test helper to create a Skhd instance from a config string
fn createTestSkhdFromConfig(allocator: std.mem.Allocator, config: []const u8) !Skhd {
    // Parse the config
    var mappings = try Mappings.init(allocator);
    errdefer mappings.deinit();

    var parser = try Parser.init(allocator);
    defer parser.deinit();

    try parser.parseWithPath(&mappings, config, "test.conf");

    // Set up default mode if it exists
    var current_mode: ?*Mode = null;
    if (mappings.mode_map.getPtr("default")) |default_mode| {
        current_mode = default_mode;
    }

    // Create carbon event mock
    const carbon_event = try CarbonEvent.init(allocator);
    errdefer carbon_event.deinit();

    return Skhd{
        .allocator = allocator,
        .mappings = mappings,
        .current_mode = current_mode,
        .event_tap = EventTap{ .mask = 0 },
        .config_file = try allocator.dupe(u8, "test.conf"),
        .verbose = false,
        .tracer = Tracer.init(false),
        .carbon_event = carbon_event,
    };
}

test "hot reload refresh is deferred until maintenance turn" {
    const allocator = std.testing.allocator;
    hotload_refresh_pending.store(false, .release);
    defer hotload_refresh_pending.store(false, .release);

    const test_id = std.crypto.random.int(u32);
    const config_path = try std.fmt.allocPrint(allocator, "/tmp/skhd_test_hotload_refresh_{d}.skhdrc", .{test_id});
    defer allocator.free(config_path);
    const include_path = try std.fmt.allocPrint(allocator, "/tmp/skhd_test_hotload_refresh_include_{d}.skhdrc", .{test_id});
    defer allocator.free(include_path);

    {
        const file = try std.fs.createFileAbsolute(config_path, .{});
        defer file.close();
        try file.writeAll("cmd - a : echo initial");
    }
    {
        const file = try std.fs.createFileAbsolute(include_path, .{});
        defer file.close();
        try file.writeAll("cmd - b : echo included");
    }
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    defer std.fs.deleteFileAbsolute(include_path) catch {};

    var skhd = try Skhd.init(allocator, config_path, false, false);
    defer skhd.deinit();

    try skhd.enableHotReload();
    try std.testing.expect(skhd.hotloader != null);
    try std.testing.expectEqual(@as(usize, 1), skhd.hotloader.?.watch_list.items.len);

    {
        const updated = try std.fmt.allocPrint(allocator,
            \\.load "{s}"
            \\cmd - a : echo reloaded
        , .{include_path});
        defer allocator.free(updated);
        const file = try std.fs.createFileAbsolute(config_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(updated);
    }

    try skhd.reloadConfig();
    try std.testing.expect(skhd.hotloader != null);
    try std.testing.expectEqual(@as(usize, 1), skhd.hotloader.?.watch_list.items.len);

    skhd.processPendingHotReloadRefresh();
    try std.testing.expect(skhd.hotloader != null);
    try std.testing.expectEqual(@as(usize, 2), skhd.hotloader.?.watch_list.items.len);
}

test "processHotkey respects passthrough in capture mode" {
    const alloc = std.testing.allocator;

    const config =
        \\:: capture @
        \\capture < cmd - a -> : echo passthrough
        \\capture < cmd - b : echo normal
        \\capture < cmd - c ~
    ;

    var skhd = try createTestSkhdFromConfig(alloc, config);
    defer skhd.deinit();

    // Switch to capture mode
    skhd.current_mode = skhd.mappings.mode_map.getPtr("capture");

    // Create mock event
    const mock_event: c.CGEventRef = @ptrFromInt(0x1234);

    // Test passthrough command
    {
        const keypress = Hotkey.KeyPress{ .key = 0x00, .flags = ModifierFlag{ .cmd = true } }; // Cmd+A
        const result = try skhd.processHotkey(&keypress, mock_event, "test");
        try std.testing.expectEqual(HotkeyResult.passthrough, result);
    }

    // Test normal command
    {
        const keypress = Hotkey.KeyPress{ .key = 0x0B, .flags = ModifierFlag{ .cmd = true } }; // Cmd+B
        const result = try skhd.processHotkey(&keypress, mock_event, "test");
        try std.testing.expectEqual(HotkeyResult.consumed, result);
    }

    // Test unbound action
    {
        const keypress = Hotkey.KeyPress{ .key = 0x08, .flags = ModifierFlag{ .cmd = true } }; // Cmd+C
        const result = try skhd.processHotkey(&keypress, mock_event, "test");
        try std.testing.expectEqual(HotkeyResult.passthrough, result);
    }

    // Test unmatched key (should return not_found, allowing capture mode to consume it)
    {
        const keypress = Hotkey.KeyPress{ .key = 0x02, .flags = ModifierFlag{ .cmd = true } }; // Cmd+D (not defined)
        const result = try skhd.processHotkey(&keypress, mock_event, "test");
        try std.testing.expectEqual(HotkeyResult.not_found, result);
    }
}

test "capture-mode wildcard: no-modifier rule matches any-modifier press" {
    // QMK-style layer transparency. `fn_layer < h | left` (no
    // modifier) should also fire when shift, ctrl, etc. are held —
    // and the user's modifiers should be carried through to the
    // forwarded keystroke.
    const alloc = std.testing.allocator;

    const config =
        \\:: fn_layer @
        \\fn_layer < 0x04 | 0x7B
    ; // 0x04 = 'h' (macOS keycode), 0x7B = left arrow

    var skhd = try createTestSkhdFromConfig(alloc, config);
    defer skhd.deinit();

    skhd.current_mode = skhd.mappings.mode_map.getPtr("fn_layer");
    const mock_event: c.CGEventRef = @ptrFromInt(0x1234);

    // No modifier — exact match (also wildcard, but exact wins).
    {
        const kp = Hotkey.KeyPress{ .key = 0x04, .flags = .{} };
        const result = try skhd.processHotkey(&kp, mock_event, "test");
        try std.testing.expectEqual(HotkeyResult.consumed, result);
    }
    // shift held — exact lookup misses, wildcard hits.
    {
        const kp = Hotkey.KeyPress{ .key = 0x04, .flags = .{ .shift = true } };
        const result = try skhd.processHotkey(&kp, mock_event, "test");
        try std.testing.expectEqual(HotkeyResult.consumed, result);
    }
    // ctrl held — same.
    {
        const kp = Hotkey.KeyPress{ .key = 0x04, .flags = .{ .control = true } };
        const result = try skhd.processHotkey(&kp, mock_event, "test");
        try std.testing.expectEqual(HotkeyResult.consumed, result);
    }
}

test "capture-mode wildcard: explicit-modifier rule wins over wildcard" {
    // If both a wildcard and an explicit-modifier rule exist for
    // the same key, the explicit one matches its exact modifier
    // combo and the wildcard handles everything else.
    const alloc = std.testing.allocator;

    const config =
        \\:: fn_layer @
        \\fn_layer < 0x04 | 0x7B
        \\fn_layer < shift - 0x04 | 0x7C
    ; // 0x7B = left, 0x7C = right

    var skhd = try createTestSkhdFromConfig(alloc, config);
    defer skhd.deinit();

    skhd.current_mode = skhd.mappings.mode_map.getPtr("fn_layer");
    const mock_event: c.CGEventRef = @ptrFromInt(0x1234);

    // shift+0x04 hits the explicit rule (→ right, no shift).
    {
        const kp = Hotkey.KeyPress{ .key = 0x04, .flags = .{ .shift = true } };
        const result = try skhd.processHotkey(&kp, mock_event, "test");
        try std.testing.expectEqual(HotkeyResult.consumed, result);
    }
    // ctrl+0x04 falls through to wildcard.
    {
        const kp = Hotkey.KeyPress{ .key = 0x04, .flags = .{ .control = true } };
        const result = try skhd.processHotkey(&kp, mock_event, "test");
        try std.testing.expectEqual(HotkeyResult.consumed, result);
    }
}

test "non-capture mode: wildcard does NOT fire" {
    // Default mode should keep strict-match semantics so users who
    // wrote `q : something` don't suddenly get matches on shift+q.
    const alloc = std.testing.allocator;

    const config =
        \\0x04 | 0x7B
    ;

    var skhd = try createTestSkhdFromConfig(alloc, config);
    defer skhd.deinit();
    const mock_event: c.CGEventRef = @ptrFromInt(0x1234);

    // Exact match: fires.
    {
        const kp = Hotkey.KeyPress{ .key = 0x04, .flags = .{} };
        const result = try skhd.processHotkey(&kp, mock_event, "test");
        try std.testing.expectEqual(HotkeyResult.consumed, result);
    }
    // shift held: default mode (non-capture), wildcard does NOT fire.
    {
        const kp = Hotkey.KeyPress{ .key = 0x04, .flags = .{ .shift = true } };
        const result = try skhd.processHotkey(&kp, mock_event, "test");
        try std.testing.expectEqual(HotkeyResult.not_found, result);
    }
}
