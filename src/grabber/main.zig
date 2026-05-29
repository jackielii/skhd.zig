//! `skhd-grabber` — system daemon, root-only.
//!
//! D1 scope: socket plumbing only. The daemon binds a Unix domain
//! socket, accepts one client connection at a time, and processes the
//! `hello` / `apply_rules` / `bye` IPC protocol. No HID seizing, no
//! virtual HID injection, no rule execution yet — those land in D2–D4.
//!
//! Run modes:
//!   skhd-grabber                            (listens on default socket)
//!   skhd-grabber --socket-path /tmp/x.sock  (dev override, no root needed)
//!   skhd-grabber --foreground               (log to stderr; otherwise
//!                                            launchd captures stdout/stderr
//!                                            via the plist)

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const c = @import("c.zig");
const protocol = @import("grabber_protocol");
const HidSeize = @import("HidSeize.zig");
const HidSystem = @import("HidSystem.zig");
const Ipc = @import("Ipc.zig");
const KbState = @import("KbState.zig");
const PowerNotify = @import("PowerNotify.zig");
const TapHold = @import("TapHold.zig");
const Vhidd = @import("Vhidd.zig");

const log = std.log.scoped(.grabber);

/// `-P/--profile` instrumentation is compiled in for Debug and
/// ReleaseSafe only — matching `Tracer.zig` in the user-agent. In
/// ReleaseFast/ReleaseSmall every profile branch folds away at
/// comptime so the seize hot path pays nothing for it.
const profile_supported = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe => .info,
        .ReleaseFast, .ReleaseSmall => .warn,
    },
};

/// Set by SIGTERM/SIGINT/SIGHUP so the accept() loop tears down on
/// next iteration. async-signal-safe by being volatile primitives only.
var should_exit: std.atomic.Value(bool) = .init(false);

/// Path of the bound socket; the SIGTERM handler uses it to unlink
/// before exit so a stale file doesn't block respawn.
var bound_socket_path: ?[]const u8 = null;

pub fn main(init: std.process.Init) !void {
    // stderr → file is block-buffered by libc default. Our SIGTERM
    // handler exits via _exit() which skips fflush, so block-buffered
    // logs from the seize loop never reach the log file. Switching
    // stderr (and stdout for symmetry) to unbuffered fixes that —
    // each log line goes to the fd immediately.
    _ = c.setvbuf(c.__stderrp, null, c._IONBF, 0);
    _ = c.setvbuf(c.__stdoutp, null, c._IONBF, 0);

    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    // io plumbed through Daemon + Vhidd.Client.connect. Other helpers
    // still rely on the legacy posix layer until they need filesystem
    // / async work.

    var socket_path: []const u8 = protocol.default_socket_path;
    var seize_test_vendor: ?u32 = null;
    var seize_test_product: ?u32 = null;
    var seize_test_duration_ms: u32 = 30_000;
    var seize_test_observe: bool = false;
    // Single inline tap-hold rule for the --seize-test debug harness.
    // The daemon path takes rules from the IPC RuleSet instead; this
    // slot only feeds seizeTest() for standalone HID-pipeline bring-up.
    var seize_test_rule: ?TapHold.Rule = null;
    // -P/--profile: emit one stderr line per HID-in / timer-sched /
    // timer-fire / vhidd-post boundary so cold-start lag and steady-
    // state cost can be measured. No effect on the no-profile path.
    var profile = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--socket-path")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --socket-path requires a path\n", .{});
                std.process.exit(2);
            }
            socket_path = args[i];
        } else if (std.mem.eql(u8, a, "--foreground")) {
            // launchd's plist handles redirection in production; flag
            // accepted for symmetry with other daemons but unused at
            // D1. D6 will hook it up to a stderr redirect.
        } else if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-v")) {
            std.debug.print("skhd-grabber (D1 skeleton)\n", .{});
            return;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, a, "--inject-test-key")) {
            injectTestKey(gpa, io) catch |err| {
                log.err("inject-test-key failed: {s}", .{@errorName(err)});
                std.process.exit(1);
            };
            return;
        } else if (std.mem.eql(u8, a, "--seize-test")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --seize-test requires <vendor>:<product> (hex)\n", .{});
                std.process.exit(2);
            }
            const pair = parseVendorProduct(args[i]) catch {
                std.debug.print("error: --seize-test arg must be VEND:PROD (e.g. 0x05AC:0x0342)\n", .{});
                std.process.exit(2);
            };
            seize_test_vendor = pair[0];
            seize_test_product = pair[1];
        } else if (std.mem.eql(u8, a, "--seize-test-observe")) {
            seize_test_observe = true;
        } else if (std.mem.eql(u8, a, "--rule")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --rule requires SRC:TAP:HOLD[@TIMEOUT_MS]\n", .{});
                std.process.exit(2);
            }
            seize_test_rule = parseRule(args[i]) catch {
                std.debug.print("error: --rule must be VEND:PROD form like 0x39:0x29:0xE0@200\n", .{});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, a, "--permissive-hold")) {
            if (seize_test_rule) |*r| r.permissive_hold = true;
        } else if (std.mem.eql(u8, a, "--hold-on-other-key-press")) {
            if (seize_test_rule) |*r| r.hold_on_other_key_press = true;
        } else if (std.mem.eql(u8, a, "-P") or std.mem.eql(u8, a, "--profile")) {
            if (comptime profile_supported) {
                profile = true;
            } else {
                log.warn("--profile ignored: this binary was built in {s} mode (compiled out for zero overhead)", .{@tagName(builtin.mode)});
            }
        } else if (std.mem.eql(u8, a, "--seize-test-duration")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --seize-test-duration requires seconds\n", .{});
                std.process.exit(2);
            }
            seize_test_duration_ms = (std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("error: invalid seconds: {s}\n", .{args[i]});
                std.process.exit(2);
            }) * 1000;
        } else {
            std.debug.print("error: unknown argument: {s}\n", .{a});
            std.process.exit(2);
        }
    }

    if (seize_test_vendor) |vendor| {
        const product = seize_test_product.?;
        const mode: HidSeize.Mode = if (seize_test_observe) .observe else .seize;
        seizeTest(gpa, io, .{ .vendor = vendor, .product = product }, seize_test_duration_ms, mode, seize_test_rule, profile) catch |err| {
            log.err("seize-test failed: {s}", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }

    log.info("skhd-grabber starting (socket={s}, pid={d})", .{ socket_path, std.c.getpid() });

    var daemon = Daemon.init(gpa, io, socket_path, profile) catch |err| {
        log.err("daemon init failed: {s}", .{@errorName(err)});
        return err;
    };
    defer daemon.deinit();

    installSignalHandlers();
    daemon.run();

    log.info("shutting down", .{});
}

/// Long-lived daemon state. The IPC listener stays alive for the
/// process's whole life so the agent can re-apply rules without
/// restarting the grabber. vhidd connection / HID seize / engine
/// slots are all rebuilt from scratch on each apply_rules — that's
/// the simple-and-correct policy until rule churn is high enough
/// that a diff-and-patch path would be a meaningful win.
/// One agent-grabber connection. The grabber keeps the socket open
/// for the lifetime of the agent, both for `mode_change` push and
/// for EOS detection: when the agent dies, our CFFileDescriptor on
/// `fd` fires and the daemon drops this subscription, falling back
/// to whatever earlier subscription was sitting underneath.
///
/// Heap-allocated so callbacks have a stable address.
const Subscription = struct {
    daemon: *Daemon,
    fd: c_int,
    uid: u32,
    stream: std.Io.net.Stream,
    rules: []protocol.Rule,
    remaps: []protocol.Remap,
    /// Mirror of NSGlobalDomain `com.apple.keyboard.fnState` as read by
    /// the agent. Drives whether bare F-row should translate to media
    /// (false, OS default) or stay literal (true).
    fkeys_as_standard: bool,
    cf_fd: c.CFFileDescriptorRef,
    cf_source: c.CFRunLoopSourceRef,
};

const Daemon = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    socket_path: []const u8,
    server: std.Io.net.Server,

    /// One per live agent connection. Most-recently-pushed apply_rules
    /// from the active console uid wins. When a subscription's socket
    /// goes EOS we drop it and fall back to the next-most-recent.
    /// Heap-allocated entries so callbacks have stable addresses.
    subscriptions: std.ArrayListUnmanaged(*Subscription) = .empty,

    /// CFFileDescriptor wrapping `server.stream.handle`. Drives the
    /// listener callback off the same CFRunLoop that handles HID
    /// seize events, so accept() and seize callbacks don't compete.
    cf_listener: c.CFFileDescriptorRef = null,
    cf_listener_source: c.CFRunLoopSourceRef = null,

    /// Lazy: connected on the first apply_rules so a daemon with no
    /// rules pending doesn't spend 3s probing vhidd at startup.
    vhidd: ?*Vhidd.Client = null,
    /// Lazy: created on first apply_rules, recreated each rebuild.
    seize: ?*HidSeize = null,
    /// Slot array owned by the Daemon, sized to the current rule list.
    slots: []EngineSlot = &.{},

    /// Stable-address state for callbacks. Kept on the Daemon so the
    /// CFFileDescriptor / CFRunLoopTimer / IOHIDManager callbacks have
    /// a fixed `info` pointer across rebuilds.
    seize_ctx: SeizeCtx,
    layer_ctx: LayerPushCtx,

    /// Active console user (foreground session). Subscriptions from
    /// agents running in *other* sessions get stored but not applied
    /// — only this uid's most-recent subscription drives seize/vhidd.
    /// Null means "no console user" (login window). D5.
    active_uid: ?u32 = null,
    /// CFRunLoopTimer that re-queries the console user every few
    /// seconds. On change, applyLatestRules re-evaluates which
    /// subscription should be active.
    console_user_timer: c.CFRunLoopTimerRef = null,

    /// Pending vhidd recovery timer, non-null while the daemon is in
    /// the "vhidd is broken, retrying" state. One-shot — the callback
    /// releases it and either schedules a new one (on failure) or
    /// clears the flag (on success).
    vhidd_recovery_timer: c.CFRunLoopTimerRef = null,
    /// Backoff for the *next* recovery attempt, in ms. 0 means "this
    /// is the first attempt, fire immediately". Doubles each failure,
    /// capped at vhidd_recovery_backoff_max_ms.
    vhidd_recovery_backoff_ms: u32 = 0,

    /// System sleep/wake hook. On wake the IOHIDManager's device refs
    /// can be silently invalidated; without this the grabber sits in
    /// CFRunLoop forever and the user's keyboard appears dead. The
    /// wake handler re-runs applyLatestRules which tears down and
    /// rebuilds vhidd + seize against the post-wake device set.
    power_notify: ?*PowerNotify = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, socket_path: []const u8, profile: bool) !Daemon {
        try ensureSocketParentDir(socket_path);
        // Stale socket from a crashed previous run: bind() would EADDRINUSE.
        // libc unlink — Daemon.init runs before io is fully wired.
        var sock_z: [std.fs.max_path_bytes]u8 = undefined;
        if (socket_path.len >= sock_z.len) return error.PathTooLong;
        @memcpy(sock_z[0..socket_path.len], socket_path);
        sock_z[socket_path.len] = 0;
        const ulrc = std.c.unlink(@ptrCast(&sock_z));
        if (ulrc != 0 and std.c.errno(ulrc) != .NOENT) return error.UnlinkFailed;

        const addr = try std.Io.net.UnixAddress.init(socket_path);
        var server = try addr.listen(io, .{});
        errdefer server.deinit(io);

        bound_socket_path = socket_path;
        // Mode 0666 so any logged-in user's agent can connect. Per-uid
        // auth lands in D5 (uid is already carried in `hello`).
        chmodPath(socket_path, 0o666) catch |err| {
            log.warn("chmod {s} failed: {s}", .{ socket_path, @errorName(err) });
        };

        // Best-effort open of IOHIDSystem. If this fails (unlikely as
        // root) we keep running — only the caps_lock force-off
        // behaviour is unavailable.
        const hidsystem: ?HidSystem = HidSystem.init() catch |err| blk: {
            log.warn("IOHIDSystem connect failed ({s}); caps_lock state won't be forced off", .{@errorName(err)});
            break :blk null;
        };

        const initial_uid = currentConsoleUid();
        if (initial_uid) |u| {
            log.info("active console user: uid={d}", .{u});
        } else {
            log.info("no active console user at startup (login window?)", .{});
        }

        return .{
            .allocator = allocator,
            .io = io,
            .socket_path = socket_path,
            .server = server,
            .seize_ctx = .{
                .state = .{},
                // vhidd pointer set on lazy connect.
                .vhidd = undefined,
                .hidsystem = hidsystem,
                .profile = profile,
                .profile_timer = if (comptime profile_supported)
                    (if (profile) ProfileTimer.start(io) else undefined)
                else
                    undefined,
            },
            .layer_ctx = .{ .stream = null, .allocator = allocator, .io = io },
            .active_uid = initial_uid,
        };
    }

    pub fn deinit(self: *Daemon) void {
        if (self.power_notify) |pn| {
            pn.deinit();
            self.power_notify = null;
        }
        self.stopConsoleUserTimer();
        self.cancelVhiddRecoveryTimer();
        self.teardownSeize();
        if (self.vhidd) |v| {
            v.close();
            self.allocator.destroy(v);
            self.vhidd = null;
        }
        // Drop every live subscription — closes their sockets, frees
        // their owned rules, releases CFFileDescriptors.
        while (self.subscriptions.items.len > 0) {
            const s = self.subscriptions.pop().?;
            self.freeSubscription(s);
        }
        self.subscriptions.deinit(self.allocator);
        if (self.cf_listener_source) |src| {
            c.CFRunLoopRemoveSource(c.CFRunLoopGetCurrent(), src, c.kCFRunLoopDefaultMode);
            c.CFRelease(src);
            self.cf_listener_source = null;
        }
        if (self.cf_listener) |fd| {
            c.CFFileDescriptorInvalidate(fd);
            c.CFRelease(fd);
            self.cf_listener = null;
        }
        if (self.seize_ctx.hidsystem) |*h| h.deinit();
        self.server.deinit(self.io);
        std.Io.Dir.deleteFileAbsolute(self.io, self.socket_path) catch {};
        bound_socket_path = null;
    }

    /// Release everything a Subscription owns. Called from
    /// handleConnectionClose and from deinit. Safe even if the
    /// CFFileDescriptor already invalidated itself.
    fn freeSubscription(self: *Daemon, s: *Subscription) void {
        c.CFRunLoopRemoveSource(c.CFRunLoopGetCurrent(), s.cf_source, c.kCFRunLoopDefaultMode);
        c.CFRelease(s.cf_source);
        c.CFFileDescriptorInvalidate(s.cf_fd);
        c.CFRelease(s.cf_fd);
        s.stream.close(self.io);
        for (s.rules) |r| if (r.hold_layer) |l| self.allocator.free(l);
        self.allocator.free(s.rules);
        self.allocator.free(s.remaps);
        self.allocator.destroy(s);
    }

    pub fn run(self: *Daemon) void {
        // Set the back-pointer now, before any seize callback can fire.
        // Daemon lives on main()'s stack so &self is stable for the
        // process lifetime.
        self.seize_ctx.daemon = self;

        self.startListenerSource() catch |err| {
            log.err("failed to start IPC listener: {s}", .{@errorName(err)});
            return;
        };
        self.startConsoleUserTimer();
        // Best-effort: if power-notification registration fails the
        // grabber still works in steady state — only the post-wake
        // recovery path is unavailable. Kept at warn (fires once, only
        // on failure) because a disarmed recovery path is worth knowing
        // about even in a release build.
        self.power_notify = PowerNotify.init(self.allocator, onSystemWake, self) catch |err| blk: {
            log.warn("PowerNotify init failed ({s}); post-wake auto-reseize disabled", .{@errorName(err)});
            break :blk null;
        };

        log.info("listening on {s}", .{self.socket_path});

        while (!should_exit.load(.acquire)) {
            const rc = c.CFRunLoopRunInMode(c.kCFRunLoopDefaultMode, 60.0, 0);
            switch (rc) {
                c.kCFRunLoopRunStopped, c.kCFRunLoopRunFinished => break,
                else => {},
            }
        }
    }

    fn startListenerSource(self: *Daemon) !void {
        var ctx: c.CFFileDescriptorContext = .{
            .version = 0,
            .info = self,
            .retain = null,
            .release = null,
            .copyDescription = null,
        };
        const cf_fd = c.CFFileDescriptorCreate(
            c.kCFAllocatorDefault,
            self.server.socket.handle,
            0, // closeOnInvalidate=false: server owns the fd
            listenerCallback,
            &ctx,
        );
        if (cf_fd == null) return error.CFFileDescriptorCreateFailed;
        errdefer c.CFRelease(cf_fd);
        self.cf_listener = cf_fd;

        const src = c.CFFileDescriptorCreateRunLoopSource(c.kCFAllocatorDefault, cf_fd, 0);
        if (src == null) return error.RunLoopSourceCreateFailed;
        self.cf_listener_source = src;

        c.CFRunLoopAddSource(c.CFRunLoopGetCurrent(), src, c.kCFRunLoopDefaultMode);
        c.CFFileDescriptorEnableCallBacks(cf_fd, c.kCFFileDescriptorReadCallBack);
    }

    fn handleListener(self: *Daemon) void {
        const conn = self.server.accept(self.io) catch |err| {
            log.warn("accept failed: {s}", .{@errorName(err)});
            return;
        };

        const result = Ipc.serve(self.allocator, self.io, conn) catch |err| blk: {
            log.warn("client session ended: {s}", .{@errorName(err)});
            break :blk Ipc.ServeResult.closed;
        };

        switch (result) {
            .closed => conn.close(self.io),
            .rules_applied => |applied| {
                self.addSubscription(conn, applied) catch |err| {
                    log.err("addSubscription failed: {s}", .{@errorName(err)});
                    applied.free(self.allocator);
                    conn.close(self.io);
                    return;
                };
                self.applyLatestRules() catch |err| {
                    log.err("applyLatestRules failed: {s}", .{@errorName(err)});
                };
            },
        }
    }

    /// Take ownership of a fresh apply_rules: wrap in a Subscription
    /// (with a CFFileDescriptor watching the socket for EOS) and add
    /// to the stack. The most recent subscription wins for active
    /// rules; on EOS its entry is dropped and the next-most-recent
    /// takes over. Subscriptions from non-active uids stay parked in
    /// the list — silenced now, candidate for "active" if the
    /// console user switches.
    fn addSubscription(self: *Daemon, stream: std.Io.net.Stream, applied: Ipc.AppliedRules) !void {
        const sub = try self.allocator.create(Subscription);
        errdefer self.allocator.destroy(sub);
        sub.* = .{
            .daemon = self,
            .fd = stream.socket.handle,
            .uid = applied.uid,
            .stream = stream,
            .rules = applied.rules,
            .remaps = applied.remaps,
            .fkeys_as_standard = applied.fkeys_as_standard,
            .cf_fd = undefined,
            .cf_source = undefined,
        };

        var ctx: c.CFFileDescriptorContext = .{
            .version = 0,
            .info = sub,
            .retain = null,
            .release = null,
            .copyDescription = null,
        };
        const cf_fd = c.CFFileDescriptorCreate(
            c.kCFAllocatorDefault,
            stream.socket.handle,
            0,
            subscriptionCallback,
            &ctx,
        );
        if (cf_fd == null) return error.CFFileDescriptorCreateFailed;
        errdefer c.CFRelease(cf_fd);

        const src = c.CFFileDescriptorCreateRunLoopSource(c.kCFAllocatorDefault, cf_fd, 0);
        if (src == null) {
            c.CFFileDescriptorInvalidate(cf_fd);
            return error.RunLoopSourceCreateFailed;
        }
        errdefer c.CFRelease(src);

        sub.cf_fd = cf_fd;
        sub.cf_source = src;

        c.CFRunLoopAddSource(c.CFRunLoopGetCurrent(), src, c.kCFRunLoopDefaultMode);
        c.CFFileDescriptorEnableCallBacks(cf_fd, c.kCFFileDescriptorReadCallBack);

        try self.subscriptions.append(self.allocator, sub);
        log.info("subscription added: uid={d} rules={d} remaps={d} (total subs={d})", .{ applied.uid, applied.rules.len, applied.remaps.len, self.subscriptions.items.len });
    }

    /// Called from subscriptionCallback when an agent's socket goes
    /// EOS or returns an unrecoverable error. Removes the entry and
    /// re-evaluates active rules (which falls back to the prior
    /// most-recent subscription, or tears down if none remain for
    /// the active uid).
    fn handleConnectionClose(self: *Daemon, sub: *Subscription) void {
        var idx: ?usize = null;
        for (self.subscriptions.items, 0..) |s, i| {
            if (s == sub) {
                idx = i;
                break;
            }
        }
        if (idx) |i| _ = self.subscriptions.orderedRemove(i);
        log.info("subscription closed: uid={d} (total subs={d})", .{ sub.uid, self.subscriptions.items.len });
        self.freeSubscription(sub);
        self.applyLatestRules() catch |err| {
            log.warn("apply after close failed: {s}", .{@errorName(err)});
        };
    }

    /// Most recent subscription owned by the active console user, or
    /// null if no subscription matches (login window, or only
    /// background-user agents are connected). D5: lets fast-user-
    /// switching toggle who drives seize without dropping anyone's
    /// stored rules.
    fn activeSubscription(self: *Daemon) ?*Subscription {
        const uid = self.active_uid orelse return null;
        var i = self.subscriptions.items.len;
        while (i > 0) : (i -= 1) {
            const s = self.subscriptions.items[i - 1];
            if (s.uid == uid) return s;
        }
        return null;
    }

    /// Called from PowerNotify when the system finishes waking. The
    /// IOHIDManager opened before sleep can be holding stale device
    /// refs; re-running applyLatestRules tears down + rebuilds vhidd
    /// + seize against the post-wake device set. Same code path as a
    /// fresh agent apply_rules so we don't carry a parallel recovery
    /// implementation.
    fn onSystemWake(ctx: ?*anyopaque) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx orelse return));
        // info: fires on every wake (several times/day), so it stays out
        // of release logs (ReleaseFast compiles out < warn). Visible in
        // a ReleaseSafe debug build if the post-wake path needs tracing.
        log.info("post-wake: re-applying current rules to refresh IOHIDManager device refs", .{});
        self.applyLatestRules() catch |err| {
            log.warn("post-wake applyLatestRules failed: {s}", .{@errorName(err)});
        };
    }

    /// (Re)build vhidd / seize / engine slots from the active
    /// subscription's rules. Called whenever the active state
    /// changes: a new agent connected, an existing one disconnected,
    /// or the console user switched. The active subscription's
    /// stream becomes the layer-push target.
    fn applyLatestRules(self: *Daemon) !void {
        const sub = self.activeSubscription() orelse {
            log.info("no active subscription — keeping seize torn down", .{});
            self.teardownSeize();
            self.layer_ctx.stream = null;
            return;
        };
        const rules = sub.rules;
        const remaps = sub.remaps;

        var has_layer_rule = false;
        var matches: std.ArrayList(HidSeize.Match) = .empty;
        defer matches.deinit(self.allocator);

        const addMatch = struct {
            fn call(allocator: std.mem.Allocator, list: *std.ArrayList(HidSeize.Match), dev: protocol.Device) !void {
                for (list.items) |m| {
                    if (m.vendor == dev.vendor and m.product == dev.product) return;
                }
                try list.append(allocator, .{ .vendor = dev.vendor, .product = dev.product });
            }
        }.call;

        for (rules) |rule| {
            const dev = rule.device orelse {
                log.err("rule src=0x{X:0>2} has no device match — global seize not supported yet", .{rule.src_usage});
                return error.MissingDevice;
            };
            if (rule.hold_layer != null) has_layer_rule = true;
            try addMatch(self.allocator, &matches, dev);
        }
        for (remaps) |rm| {
            try addMatch(self.allocator, &matches, rm.device);
        }

        log.info("apply_rules: {d} rule(s), {d} remap(s) across {d} device(s) layer_push={}", .{ rules.len, remaps.len, matches.items.len, has_layer_rule });
        for (rules, 0..) |rule, i| {
            const hold_str: []const u8 = if (rule.hold_layer) |l| l else "<hid_usage>";
            log.info(
                "  rule[{d}]: src=0x{X:0>2} tap=0x{X:0>2} hold={s} timeout={d}ms perm={} hokp={}",
                .{ i, rule.src_usage, rule.tap_usage, hold_str, rule.timeout_ms, rule.permissive_hold, rule.hold_on_other_key_press },
            );
        }
        for (remaps, 0..) |rm, i| {
            log.info("  remap[{d}]: src=0x{X:0>2} → dst=0x{X:0>2}", .{ i, rm.src_usage, rm.dst_usage });
        }

        // Release the physical keyboard FIRST. The seize must never be
        // held across the (potentially blocking, up-to-5s) vhidd connect
        // below: a stale or dead vhidd would otherwise leave every
        // keystroke captured-but-undeliverable — a dead keyboard. With
        // the seize torn down the keyboard falls back to the real HID
        // path until we re-seize at the end of this function. HidSeize is
        // also a one-process singleton, so it must be released before the
        // HidSeize.init below runs again.
        self.teardownSeize();

        // Lazy vhidd init on first apply (or after a recovery nulled it).
        if (self.vhidd == null) {
            log.info("connecting to vhidd_server", .{});
            const v = try self.allocator.create(Vhidd.Client);
            errdefer self.allocator.destroy(v);
            v.* = try Vhidd.Client.connect(self.allocator, self.io);
            errdefer v.close();
            log.info("initializing virtual keyboard", .{});
            try v.initializeKeyboard(.{});
            try v.waitForBoolTrue(.virtual_hid_keyboard_ready, 5000);
            log.info("virtual keyboard ready", .{});
            self.vhidd = v;
            self.seize_ctx.vhidd = v;
        }

        // Layer push target = the active subscription's stream
        // (always live now thanks to per-connection tracking — the
        // grabber doesn't close subscriptions out from under their
        // owners any more).
        self.layer_ctx.stream = if (has_layer_rule) sub.stream else null;

        // (Seize already torn down above, before the vhidd connect.)

        // Build slots and seize as locals first. Don't expose to
        // `self` until everything's wired up — otherwise a failure
        // partway through (e.g. seize.start returning NotPermitted
        // because TCC denied us) leaves self.slots pointing at memory
        // that errdefer just freed, and the next teardownSeize crashes
        // iterating it.
        const slots = try self.allocator.alloc(EngineSlot, rules.len);
        errdefer self.allocator.free(slots);

        for (rules, 0..) |rule, i| {
            const hold_action: TapHold.HoldAction = if (rule.hold_layer) |layer_name| .{ .layer = layer_name } else .{
                .hid_usage = std.math.cast(u16, rule.hold_usage) orelse return error.HoldUsageOverflow,
            };
            const th_rule: TapHold.Rule = .{
                .src_usage = std.math.cast(u16, rule.src_usage) orelse return error.SourceUsageOverflow,
                .tap_usage = std.math.cast(u16, rule.tap_usage) orelse return error.TapUsageOverflow,
                .hold = hold_action,
                .timeout_ms = rule.timeout_ms,
                .permissive_hold = rule.permissive_hold,
                .hold_on_other_key_press = rule.hold_on_other_key_press,
                .retro_tap = rule.retro_tap,
            };
            slots[i] = .{
                .seize_ctx = &self.seize_ctx,
                .engine = TapHold.initWithLayerSink(
                    th_rule,
                    emitToVhidd,
                    &self.seize_ctx,
                    layerPushSink,
                    &self.layer_ctx,
                ),
            };
            slots[i].engine.arbitration_hook = arbitrateHoldCommit;
            slots[i].engine.arbitration_ctx = &self.seize_ctx;
        }

        const seize = try HidSeize.init(self.allocator, seizeInputCallback, &self.seize_ctx);
        errdefer seize.deinit();
        try seize.setMatches(matches.items);
        try seize.start(.seize);

        // Past the failure boundary: commit ownership atomically.
        self.slots = slots;
        self.seize_ctx.slots = slots;
        self.seize = seize;

        // Cache: do we have any caps_lock remap? Drives the per-event
        // force-off in seizeInputCallback.
        var caps_active = false;
        for (slots) |*s| {
            if (s.engine.rule.src_usage == 0x39) {
                caps_active = true;
                break;
            }
        }
        self.seize_ctx.caps_remap_active = caps_active;
        self.seize_ctx.fkeys_as_standard = sub.fkeys_as_standard;

        // Rebuild the colon-form remap table. Reset to all-zero first
        // so a previously-installed rule that's no longer present is
        // forgotten.
        self.seize_ctx.remap_table = @splat(0);
        for (remaps) |rm| {
            if (rm.src_usage >= self.seize_ctx.remap_table.len) {
                log.warn("remap src=0x{X} out of HID page-7 range — skipping", .{rm.src_usage});
                continue;
            }
            const dst16 = std.math.cast(u16, rm.dst_usage) orelse {
                log.warn("remap dst=0x{X} out of u16 range — skipping", .{rm.dst_usage});
                continue;
            };
            self.seize_ctx.remap_table[rm.src_usage] = dst16;
        }

        log.info("seize active — re-apply by sending another apply_rules over the IPC socket", .{});
    }

    fn teardownSeize(self: *Daemon) void {
        if (self.seize) |s| {
            s.stop();
            s.deinit();
            self.seize = null;
        }
        for (self.slots) |*slot| cancelTapHoldTimer(slot);
        if (self.slots.len > 0) self.allocator.free(self.slots);
        self.slots = &.{};
        self.seize_ctx.slots = &.{};
        self.seize_ctx.caps_remap_active = false;
        self.seize_ctx.remap_table = @splat(0);
        // Drop any virtual keys we left held so a re-apply starts clean.
        self.seize_ctx.consumer_state.clear();
        self.seize_ctx.apple_top_case_state.clear();
        self.seize_ctx.apple_keyboard_state.clear();
        self.seize_ctx.generic_desktop_state.clear();
        if (self.vhidd) |v| {
            v.postKeyboardReport(.{}, &.{}) catch {};
            v.postConsumerReport(&.{}) catch {};
            v.postAppleVendorTopCaseReport(&.{}) catch {};
            v.postAppleVendorKeyboardReport(&.{}) catch {};
            v.postGenericDesktopReport(&.{}) catch {};
        }
    }

    /// Poll the active console user every 3 seconds. On change, log
    /// the transition and rebuild seize from the new uid's stored
    /// rules (or tear down if they have none). Polling is much
    /// simpler than SCDynamicStore notification subscription and the
    /// 3s latency is well within human-noticeable limits for a
    /// fast-user-switch.
    fn startConsoleUserTimer(self: *Daemon) void {
        if (self.console_user_timer != null) return;
        var ctx: c.CFRunLoopTimerContext = .{
            .version = 0,
            .info = self,
            .retain = null,
            .release = null,
            .copyDescription = null,
        };
        const interval: f64 = 3.0;
        const fire_at = c.CFAbsoluteTimeGetCurrent() + interval;
        self.console_user_timer = c.CFRunLoopTimerCreate(
            c.kCFAllocatorDefault,
            fire_at,
            interval,
            0,
            0,
            consoleUserTimerCallback,
            &ctx,
        );
        if (self.console_user_timer == null) {
            log.warn("could not create console_user timer; fast-user-switching may not be picked up", .{});
            return;
        }
        c.CFRunLoopAddTimer(c.CFRunLoopGetCurrent(), self.console_user_timer, c.kCFRunLoopDefaultMode);
    }

    fn stopConsoleUserTimer(self: *Daemon) void {
        if (self.console_user_timer) |t| {
            c.CFRunLoopTimerInvalidate(t);
            c.CFRelease(t);
            self.console_user_timer = null;
        }
    }

    /// Entry point from the seize callback when a vhidd send fails.
    /// Latches `vhidd_broken` and queues a recovery pass for the next
    /// runloop iteration. Idempotent — concurrent failures collapse
    /// onto a single recovery pass.
    ///
    /// Why not release seize here? markVhiddBroken runs inside the
    /// IOHIDManager value callback, and teardownSeize calls
    /// IOHIDManagerClose / IOHIDManagerUnscheduleFromRunLoop on the
    /// same manager that's mid-dispatch — Apple's docs don't promise
    /// that's safe. Defer the teardown to the timer callback, which
    /// fires *between* runloop sources. The vhidd_broken flag
    /// short-circuits further posts in the meantime so we don't spam
    /// the log on any events delivered in the same runloop pass.
    fn markVhiddBroken(self: *Daemon) void {
        if (self.seize_ctx.vhidd_broken) return;
        self.seize_ctx.vhidd_broken = true;
        log.warn("vhidd transport broken — releasing seize, will retry connect", .{});
        self.scheduleVhiddRecovery(0);
    }

    fn scheduleVhiddRecovery(self: *Daemon, delay_ms: u32) void {
        self.cancelVhiddRecoveryTimer();
        var ctx: c.CFRunLoopTimerContext = .{
            .version = 0,
            .info = self,
            .retain = null,
            .release = null,
            .copyDescription = null,
        };
        const fire_at = c.CFAbsoluteTimeGetCurrent() + @as(f64, @floatFromInt(delay_ms)) / 1000.0;
        const timer = c.CFRunLoopTimerCreate(
            c.kCFAllocatorDefault,
            fire_at,
            0, // one-shot
            0,
            0,
            vhiddRecoveryTimerCallback,
            &ctx,
        );
        if (timer == null) {
            log.err("vhidd recovery timer create failed — manual restart required", .{});
            return;
        }
        self.vhidd_recovery_timer = timer;
        c.CFRunLoopAddTimer(c.CFRunLoopGetCurrent(), timer, c.kCFRunLoopDefaultMode);
    }

    fn cancelVhiddRecoveryTimer(self: *Daemon) void {
        if (self.vhidd_recovery_timer) |t| {
            c.CFRunLoopTimerInvalidate(t);
            c.CFRelease(t);
            self.vhidd_recovery_timer = null;
        }
    }

    /// Body of the recovery timer callback. Release seize (so real
    /// keystrokes flow to the OS), close the dead client, then run
    /// applyLatestRules (which lazy-connects vhidd and re-seizes).
    /// On failure, reschedule with backoff.
    fn attemptVhiddRecovery(self: *Daemon) void {
        // Safe to tear down here — the timer callback is invoked
        // between runloop sources, not from inside a seize callback.
        self.teardownSeize();
        if (self.vhidd) |v| {
            v.close();
            self.allocator.destroy(v);
            self.vhidd = null;
            // Leave seize_ctx.vhidd alone — applyLatestRules will
            // overwrite it on successful reconnect. Reading it before
            // then would be unsafe, but the seize is torn down so no
            // callback can do that.
        }
        self.applyLatestRules() catch |err| {
            const next = Vhidd.nextBackoffMs(self.vhidd_recovery_backoff_ms);
            log.warn("vhidd reconnect failed: {s} — retrying in {d}ms", .{ @errorName(err), next });
            self.vhidd_recovery_backoff_ms = next;
            self.scheduleVhiddRecovery(next);
            return;
        };
        log.info("vhidd reconnected — seize reactivated", .{});
        self.seize_ctx.vhidd_broken = false;
        self.vhidd_recovery_backoff_ms = 0;
    }
};


fn consoleUserTimerCallback(_: c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const d: *Daemon = @ptrCast(@alignCast(info orelse return));
    const new_uid = currentConsoleUid();
    if (new_uid == d.active_uid) return; // no change

    log.info("active console user changed: {?d} → {?d}", .{ d.active_uid, new_uid });
    d.active_uid = new_uid;
    // Rebuild from the (possibly new) uid's rules. No agent_conn
    // because this rebuild isn't triggered by an agent message —
    // when the new user's agent next sends apply_rules, that path
    // wires up layer push.
    d.applyLatestRules() catch |err| {
        log.warn("rebuild after console user change failed: {s}", .{@errorName(err)});
    };
}

fn vhiddRecoveryTimerCallback(_: c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const d: *Daemon = @ptrCast(@alignCast(info orelse return));
    // The timer is one-shot — release its ref before doing work so a
    // re-schedule from attemptVhiddRecovery doesn't fight with it.
    if (d.vhidd_recovery_timer) |t| {
        c.CFRunLoopTimerInvalidate(t);
        c.CFRelease(t);
        d.vhidd_recovery_timer = null;
    }
    d.attemptVhiddRecovery();
}

fn listenerCallback(
    cf_fd: c.CFFileDescriptorRef,
    callback_types: c.CFOptionFlags,
    info: ?*anyopaque,
) callconv(.c) void {
    _ = callback_types;
    const d: *Daemon = @ptrCast(@alignCast(info orelse return));
    d.handleListener();
    // CFFileDescriptor is one-shot: re-arm so the next pending
    // accept fires another callback.
    c.CFFileDescriptorEnableCallBacks(cf_fd, c.kCFFileDescriptorReadCallBack);
}

/// CFFileDescriptor callback for an active Subscription's socket.
/// Fires either when the agent writes to us (which it shouldn't —
/// the post-apply_rules direction is server → client only) or when
/// the OS marks the fd readable due to EOS (peer closed). Either
/// way we attempt a 1-byte read; 0-byte recv → EOS → drop the sub.
/// A successful read of unexpected bytes is logged but kept alive.
fn subscriptionCallback(
    cf_fd: c.CFFileDescriptorRef,
    callback_types: c.CFOptionFlags,
    info: ?*anyopaque,
) callconv(.c) void {
    _ = callback_types;
    const sub: *Subscription = @ptrCast(@alignCast(info orelse return));

    var byte: [1]u8 = undefined;
    const n = c.recv(sub.fd, &byte, byte.len, c.MSG_PEEK | c.MSG_DONTWAIT);
    if (n < 0) {
        // EAGAIN and EWOULDBLOCK share the same value on macOS; one match
        // covers both per recv(2). Anything else means the connection is
        // gone and we drop the subscription.
        const errno = std.c._errno().*;
        if (errno == @intFromEnum(std.c.E.AGAIN)) {
            c.CFFileDescriptorEnableCallBacks(cf_fd, c.kCFFileDescriptorReadCallBack);
            return;
        }
        log.info("subscription recv error (errno={d}) — dropping", .{errno});
        sub.daemon.handleConnectionClose(sub);
        return;
    }
    if (n == 0) {
        // Peer closed cleanly.
        sub.daemon.handleConnectionClose(sub);
        return;
    }
    // Unexpected stray data from agent. Drain it and stay armed —
    // the agent shouldn't send anything after apply_rules but we
    // tolerate it rather than tear down.
    log.warn("subscription uid={d}: unexpected {d} byte(s) from agent — discarding", .{ sub.uid, n });
    var drain: [256]u8 = undefined;
    _ = c.recv(sub.fd, &drain, drain.len, c.MSG_DONTWAIT);
    c.CFFileDescriptorEnableCallBacks(cf_fd, c.kCFFileDescriptorReadCallBack);
}

/// Read the current foreground console user uid, or null at the
/// login window (no user logged in graphically). Calls
/// SCDynamicStoreCopyConsoleUser with a null store, the canonical
/// "just give me the current value, no subscription" form.
fn currentConsoleUid() ?u32 {
    var uid: c.uid_t = 0;
    const name = c.SCDynamicStoreCopyConsoleUser(null, &uid, null);
    if (name == null) return null;
    c.CFRelease(name);
    // SCDynamicStoreCopyConsoleUser returns "loginwindow" with uid=0
    // at the login screen. Treat any uid < 500 (system uids) as
    // "no console user" — real users on macOS start at 501.
    if (uid < 500) return null;
    return @intCast(uid);
}

fn ensureSocketParentDir(socket_path: []const u8) !void {
    const dir = std.fs.path.dirname(socket_path) orelse return;
    var stack: [std.fs.max_path_bytes]u8 = undefined;
    if (dir.len >= stack.len) return error.PathTooLong;
    @memcpy(stack[0..dir.len], dir);
    stack[dir.len] = 0;
    if (std.c.mkdir(@ptrCast(&stack), 0o755) != 0) {
        if (std.c.errno(@as(c_int, -1)) != .EXIST) return error.MkdirFailed;
    }
}

fn chmodPath(path: []const u8, mode: u32) !void {
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const rc = std.c.chmod(&path_buf, @intCast(mode));
    if (rc != 0) return error.ChmodFailed;
}

fn installSignalHandlers() void {
    var act: posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.TERM, &act, null);
    posix.sigaction(.INT, &act, null);
    posix.sigaction(.HUP, &act, null);
    // SIGPIPE: client dropped mid-write; we want EPIPE from write() and
    // graceful continue, not whole-process termination.
    var ignore: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.PIPE, &ignore, null);
}

fn handleSignal(_: posix.SIG) callconv(.c) void {
    should_exit.store(true, .release);
    // Best-effort unlink so the next launchd respawn binds cleanly.
    // Path access is safe here because we set bound_socket_path once
    // at startup before installing this handler.
    if (bound_socket_path) |p| {
        var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        if (p.len < path_buf.len) {
            @memcpy(path_buf[0..p.len], p);
            path_buf[p.len] = 0;
            _ = std.c.unlink(&path_buf);
        }
    }
    // accept() in the main loop retries internally on EINTR, so just
    // setting a flag isn't enough to unblock it. _exit forces a clean
    // shutdown without running atexit/destructors — fine here because
    // the only stateful resource is the socket file we just unlinked.
    // D5 will replace this with a self-pipe / kqueue wake-up so we can
    // run normal teardown.
    std.c._exit(0);
}

/// Connect to vhidd_server, initialize the virtual keyboard, wait for
/// the ready signal, then send Escape keydown + keyup. Used to verify
/// the Karabiner DriverKit injection path end-to-end (D2 phase).
fn injectTestKey(allocator: std.mem.Allocator, io: std.Io) !void {
    log.info("connecting to vhidd_server…", .{});
    var client = try Vhidd.Client.connect(allocator, io);
    defer client.close();

    log.info("initializing virtual keyboard…", .{});
    try client.initializeKeyboard(.{});

    log.info("waiting for virtual_hid_keyboard_ready=true…", .{});
    try client.waitForBoolTrue(.virtual_hid_keyboard_ready, 5000);
    log.info("keyboard ready", .{});

    // Brief settle; in practice the ready signal is enough but Apple
    // Silicon DriverKit sometimes needs a beat before injection lands
    // reliably (matches the example client's 100ms post-ready sleep).
    std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};

    // 'a' (HID 0x04). Picked over Escape because Escape is invisible in
    // most terminals — 'a' shows up on screen so injection success is
    // self-evident. The test only proves the wire path; the choice of
    // key is irrelevant.
    const test_usage: u16 = 0x04;
    log.info("posting keydown (a, HID 0x{X:0>2})", .{test_usage});
    try client.postKeyboardReport(.{}, &.{test_usage});

    std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};

    log.info("posting keyup (empty)", .{});
    try client.postKeyboardReport(.{}, &.{});

    // Small post-write grace period before close so the kernel has
    // time to deliver our final keyup before we tear the socket down.
    std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    log.info("done", .{});
}

/// One TapHold engine + its currently-active CFRunLoopTimer. The
/// timer's `info` points back at the slot so the timer callback can
/// drive `engine.timerFired()` and apply the next action without
/// scanning a list.
const EngineSlot = struct {
    seize_ctx: *SeizeCtx,
    engine: TapHold,
    timer: c.CFRunLoopTimerRef = null,
    /// Profile-only: ns-since-Timer-start when this slot's hold timer
    /// is supposed to fire. Set in applyTapHoldTimer when scheduling
    /// `start_in_ms`; read in tapHoldTimerCallback to compute drift
    /// (actual fire − requested fire). Unread when profile is off.
    profile_pending_fire_ns: u64 = 0,
};

/// State carried into the HidSeize input value callback. We can't
/// closure-capture, so callers stash whatever the callback needs into
/// a struct and pass its address as the void* context.
const SeizeCtx = struct {
    state: KbState,
    /// Per-page snapshot state for the non-keyboard HID pages we
    /// forward through vhidd. Apple's built-in keyboard reports
    /// media keys (volume, brightness, play/pause, …) on these pages
    /// when the "Use F1, F2… as standard function keys" setting is
    /// off, and seize captures them alongside the keyboard page —
    /// so we have to forward them ourselves or the user loses every
    /// F-row default action.
    consumer_state: KbState.PageState = .{},
    apple_top_case_state: KbState.PageState = .{},
    apple_keyboard_state: KbState.PageState = .{},
    generic_desktop_state: KbState.PageState = .{},
    vhidd: *Vhidd.Client,
    /// One slot per active rule. Empty in --inject-test-key /
    /// --seize-test pass-through paths; populated in the daemon
    /// loop after apply_rules.
    slots: []EngineSlot = &.{},
    forwarded: u64 = 0,
    skipped_other_pages: u64 = 0,
    /// IOHIDSystem connection used to force caps_lock state off after
    /// Apple firmware would otherwise toggle it. Null when the open
    /// failed (we still process events; only the caps_lock-neutralize
    /// behaviour is skipped).
    hidsystem: ?HidSystem = null,
    /// Cached: any active rule has src_usage = 0x39. When false, we
    /// skip the per-event caps_lock force-off so we don't interfere
    /// with users who haven't remapped caps_lock.
    caps_remap_active: bool = false,
    /// Mirror of NSGlobalDomain `com.apple.keyboard.fnState` from the
    /// active subscription. Decides whether bare F-row should run
    /// `translateFRow` (false → media keys) or pass through as a
    /// literal F<i> keyboard-page event (true → F-keys are the OS
    /// default, fn-modifier flips back to media). Read on each
    /// `applyLatestRules`.
    fkeys_as_standard: bool = false,
    /// Colon-form `.remap` table. Indexed by HID usage (page 0x07
    /// only). Zero means "no remap"; any nonzero value rewrites the
    /// source usage on its way in. Sized to 0x100 — covers every
    /// keyboard usage. Allocated once and reused on each rule
    /// rebuild. We don't device-key this in v1 — typical user has
    /// one seized device and remaps target it by alias anyway.
    remap_table: [0x100]u16 = @splat(0),
    /// -P/--profile: emit timeline traces. Off-path is unaffected.
    profile: bool = false,
    /// Monotonic clock anchor used by profile traces. Only valid when
    /// `profile` is true; left undefined otherwise so the no-profile
    /// path doesn't pay for the syscall.
    profile_timer: ProfileTimer = undefined,
    /// Back-pointer for the seize callback to reach Daemon helpers
    /// (specifically markVhiddBroken on a vhidd send failure). Set
    /// once in Daemon.run() before any callback can fire — Daemon
    /// lives on main()'s stack so its address is stable for the
    /// process lifetime.
    daemon: ?*Daemon = null,
    /// Latched once vhidd post fails, cleared when recovery succeeds.
    /// Reads in the seize callback short-circuit further post attempts
    /// while a recovery is pending, so we don't burn cycles + log
    /// noise on every event between the first failure and the timer
    /// firing on the next runloop tick.
    vhidd_broken: bool = false,
};

/// std.time.Timer was removed in Zig 0.16. `std.Io.Clock.Timestamp.now(io,
/// .awake)` is the monotonic-clock replacement (`.awake` excludes time
/// the system was suspended; on macOS this maps to `CLOCK_UPTIME_RAW`).
/// Subtracting two reads gives ns-since-start for the profile traces.
const ProfileTimer = struct {
    io: std.Io,
    start_ns: i128 = 0,

    pub fn start(io: std.Io) ProfileTimer {
        const ts = std.Io.Clock.Timestamp.now(io, .awake);
        return .{ .io = io, .start_ns = ts.raw.nanoseconds };
    }

    pub fn read(self: *ProfileTimer) u64 {
        const ts = std.Io.Clock.Timestamp.now(self.io, .awake);
        const delta = ts.raw.nanoseconds - self.start_ns;
        return if (delta < 0) 0 else @intCast(delta);
    }
};

/// Profile-trace helper: ns-since-`profile_timer.start()` cast to
/// microseconds for compact stderr output. Caller is responsible for
/// gating with `cx.profile` so the cost is paid only when enabled.
inline fn profUs(cx: *SeizeCtx) u64 {
    return cx.profile_timer.read() / std.time.ns_per_us;
}

/// State for the layer-hold sink: a borrowed agent IPC stream + the
/// allocator we use to build outbound JSON payloads.
const LayerPushCtx = struct {
    stream: ?std.Io.net.Stream,
    allocator: std.mem.Allocator,
    io: std.Io,
};

/// TapHold layer sink: write a `mode_change` message back to the
/// agent over the live IPC connection. Failures are logged but
/// don't propagate — the seize loop must keep running even if the
/// agent has disconnected. (D6 will detect that and reset state.)
fn layerPushSink(ctx_ptr: ?*anyopaque, layer: []const u8, entering: bool) void {
    const lctx: *LayerPushCtx = @ptrCast(@alignCast(ctx_ptr orelse return));
    const stream = lctx.stream orelse {
        log.warn("layer transition '{s}' entering={} dropped — no agent connection", .{ layer, entering });
        return;
    };

    // On exit, an empty mode name tells the agent "fall back to
    // default". Push the layer name on enter so multi-layer setups
    // can target named modes individually.
    const target: []const u8 = if (entering) layer else "";
    var wbuf: [256]u8 = undefined;
    var sw = stream.writer(lctx.io, &wbuf);
    protocol.writeMessage(&sw.interface, lctx.allocator, .{
        .@"type" = "mode_change",
        .mode = target,
    }) catch |err| {
        log.warn("mode_change push failed: {s}", .{@errorName(err)});
        return;
    };
    sw.interface.flush() catch |err| {
        log.warn("mode_change flush failed: {s}", .{@errorName(err)});
    };
}

/// TapHold arbitration hook. Invoked from a slot's
/// `doHoldCommit` (permissive_hold / hold_on_other_key_press /
/// timer-fire). Repro: holding space (→ fn_layer, layer rule) AND
/// caps_lock (→ lctrl, permissive_hold) and tapping h would
/// occasionally land a bare ctrl-h at the OS — caps's
/// permissive_hold fires on h-up while space is still in pending
/// and pushes the modifier replay before the layer ever gets
/// pushed. Here we look for any other slot that is in pending and
/// is a layer rule, and force it to push its layer first. The
/// layer slot's buffered events are split: events that the
/// committing slot also has are dropped (its flushBuffer will
/// replay them under the modifier), and any unique prefix
/// (events that arrived before the committing slot started
/// pending) is replayed now under the layer.
fn arbitrateHoldCommit(ctx_ptr: ?*anyopaque, committing: *TapHold) void {
    const cx: *SeizeCtx = @ptrCast(@alignCast(ctx_ptr orelse return));
    const committing_buf = committing.bufferedCount();
    for (cx.slots) |*slot| {
        if (&slot.engine == committing) continue;
        if (slot.engine.state != .pending) continue;
        if (!slot.engine.isLayer()) continue;

        const layer_len = slot.engine.bufferedCount();
        const unique_prefix = if (layer_len > committing_buf) layer_len - committing_buf else 0;

        slot.engine.forceLayerEnter();
        cancelTapHoldTimer(slot);
        slot.engine.flushPrefixAndDiscardRest(unique_prefix);
    }
}

/// Sink for both real HID events and TapHold-synthesized events.
/// Aggregates the transition into KbState and posts a vhidd report.
fn emitToVhidd(ctx_ptr: ?*anyopaque, ev: TapHold.Event) void {
    const cx: *SeizeCtx = @ptrCast(@alignCast(ctx_ptr orelse return));
    if (ev.usage_page != 0x07) return;
    const usage16 = std.math.cast(u16, ev.usage) orelse return;
    if (usage16 < 0x04) return;
    if (!cx.state.applyKeyboardEvent(usage16, ev.pressed)) return;

    log.info("emit: usage=0x{X:0>2} pressed={}", .{ usage16, ev.pressed });

    // Short-circuit if a previous post already triggered recovery —
    // the seize tear-down is scheduled on the runloop and any events
    // already in flight would otherwise spam the log.
    if (cx.vhidd_broken) return;

    const held = cx.state.compactedKeys();
    const t_pre: u64 = if (comptime profile_supported) (if (cx.profile) cx.profile_timer.read() else 0) else 0;
    cx.vhidd.postKeyboardReport(cx.state.modifiers, held) catch |err| {
        log.warn("vhidd post failed: {s}", .{@errorName(err)});
        if (Vhidd.isTransportError(err)) {
            if (cx.daemon) |d| d.markVhiddBroken();
        }
        return;
    };
    if (comptime profile_supported) {
        if (cx.profile) {
            const t_post = cx.profile_timer.read();
            std.debug.print("[prof] vhidd-post t={d}us cost={d}us usage=0x{X:0>2} pressed={}\n", .{
                t_post / std.time.ns_per_us, (t_post - t_pre) / std.time.ns_per_us, usage16, ev.pressed,
            });
        }
    }
    cx.forwarded += 1;
}

fn applyTapHoldTimer(slot: *EngineSlot, action: TapHold.TimerAction) void {
    switch (action) {
        .none => {},
        .cancel => cancelTapHoldTimer(slot),
        .start_in_ms => |ms| {
            cancelTapHoldTimer(slot);
            if (comptime profile_supported) {
                if (slot.seize_ctx.profile) {
                    const now_ns = slot.seize_ctx.profile_timer.read();
                    slot.profile_pending_fire_ns = now_ns + @as(u64, ms) * std.time.ns_per_ms;
                    std.debug.print("[prof] timer-sched t={d}us src=0x{X:0>2} fire-after={d}ms\n", .{
                        now_ns / std.time.ns_per_us, slot.engine.rule.src_usage, ms,
                    });
                }
            }
            slot.timer = makeTapHoldTimer(ms, slot);
            c.CFRunLoopAddTimer(c.CFRunLoopGetCurrent(), slot.timer, c.kCFRunLoopDefaultMode);
        },
    }
}

fn cancelTapHoldTimer(slot: *EngineSlot) void {
    if (slot.timer != null) {
        // Invalidate first so the run loop drops its strong ref AND
        // so the timer never fires (otherwise CFRelease alone would
        // keep the timer scheduled — the run loop still owns its own
        // retain via CFRunLoopAddTimer, and the timer would later fire
        // a stale callback that could mis-commit a hold during the
        // next tap's pending state).
        c.CFRunLoopTimerInvalidate(slot.timer);
        c.CFRelease(slot.timer);
        slot.timer = null;
    }
}

fn tapHoldTimerCallback(_: c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const slot: *EngineSlot = @ptrCast(@alignCast(info orelse return));
    if (comptime profile_supported) {
        if (slot.seize_ctx.profile) {
            const now_ns = slot.seize_ctx.profile_timer.read();
            // Drift = actual fire − requested fire, in microseconds.
            // Positive means the runloop fired late; large positive on
            // the first hold after startup would be the cold-start
            // signal we're hunting.
            const now_us: i128 = @intCast(now_ns / std.time.ns_per_us);
            const want_us: i128 = @intCast(slot.profile_pending_fire_ns / std.time.ns_per_us);
            std.debug.print("[prof] timer-fire t={d}us src=0x{X:0>2} drift={d}us\n", .{
                now_ns / std.time.ns_per_us, slot.engine.rule.src_usage, now_us - want_us,
            });
        }
    }
    const action = slot.engine.timerFired();
    // The timer that just fired is now expired — drop our handle
    // before applying any new timer action so we don't try to
    // CFRelease a freed-by-runloop reference if the engine asks
    // for cancel.
    if (slot.timer != null) {
        c.CFRunLoopTimerInvalidate(slot.timer);
        c.CFRelease(slot.timer);
        slot.timer = null;
    }
    applyTapHoldTimer(slot, action);
}

fn makeTapHoldTimer(after_ms: u32, slot: *EngineSlot) c.CFRunLoopTimerRef {
    const fire_date = c.CFAbsoluteTimeGetCurrent() + @as(f64, @floatFromInt(after_ms)) / 1000.0;
    var context: c.CFRunLoopTimerContext = .{
        .version = 0,
        .info = slot,
        .retain = null,
        .release = null,
        .copyDescription = null,
    };
    return c.CFRunLoopTimerCreate(
        c.kCFAllocatorDefault,
        fire_date,
        0,
        0,
        0,
        tapHoldTimerCallback,
        &context,
    );
}

/// Where to route a translated F-row press. Indexes into the
/// non-keyboard-page states owned by SeizeCtx.
const FRowTarget = union(enum) {
    consumer: u16,
    apple_vendor_keyboard: u16,
    generic_desktop: u16,
};

/// F1..F12 → media-key translation, matches Karabiner's defaults
/// for Apple built-in keyboards (see fn_function_keys_manipulator).
/// Indexed by `usage - 0x3A`.
const f_row_translation = [12]FRowTarget{
    .{ .consumer = 0x70 }, // F1  display_brightness_decrement
    .{ .consumer = 0x6F }, // F2  display_brightness_increment
    .{ .apple_vendor_keyboard = 0x10 }, // F3  mission_control
    .{ .apple_vendor_keyboard = 0x01 }, // F4  spotlight
    .{ .consumer = 0xCF }, // F5  voice_command (dictation)
    .{ .generic_desktop = 0x9B }, // F6  do_not_disturb
    .{ .consumer = 0xB4 }, // F7  rewind
    .{ .consumer = 0xCD }, // F8  play_or_pause
    .{ .consumer = 0xB3 }, // F9  fast_forward
    .{ .consumer = 0xE2 }, // F10 mute
    .{ .consumer = 0xEA }, // F11 volume_decrement
    .{ .consumer = 0xE9 }, // F12 volume_increment
};

fn translateFRow(cx: *SeizeCtx, raw_usage16: u16, pressed: bool) void {
    const idx: usize = raw_usage16 - 0x3A;
    const target = f_row_translation[idx];
    switch (target) {
        .consumer => |u| {
            if (!cx.consumer_state.apply(u, pressed)) return;
            cx.vhidd.postConsumerReport(cx.consumer_state.compacted()) catch |err| {
                log.warn("vhidd consumer post failed: {s}", .{@errorName(err)});
            };
        },
        .apple_vendor_keyboard => |u| {
            if (!cx.apple_keyboard_state.apply(u, pressed)) return;
            cx.vhidd.postAppleVendorKeyboardReport(cx.apple_keyboard_state.compacted()) catch |err| {
                log.warn("vhidd apple-keyboard post failed: {s}", .{@errorName(err)});
            };
        },
        .generic_desktop => |u| {
            if (!cx.generic_desktop_state.apply(u, pressed)) return;
            cx.vhidd.postGenericDesktopReport(cx.generic_desktop_state.compacted()) catch |err| {
                log.warn("vhidd generic-desktop post failed: {s}", .{@errorName(err)});
            };
        },
    }
}

fn seizeInputCallback(ctx: ?*anyopaque, ev: HidSeize.Event) void {
    const cx: *SeizeCtx = @ptrCast(@alignCast(ctx orelse return));

    if (comptime profile_supported) {
        if (cx.profile) {
            std.debug.print("[prof] hid-in t={d}us page=0x{X:0>2} usage=0x{X:0>4} pressed={}\n", .{
                profUs(cx), ev.usage_page, ev.usage, ev.pressed,
            });
        }
    }

    log.debug("hid event: page=0x{X:0>2} usage=0x{X:0>4} pressed={}", .{
        ev.usage_page,
        ev.usage,
        ev.pressed,
    });

    // Forward non-keyboard pages straight through vhidd so the F-row
    // default media actions (volume, brightness, play/pause, …) keep
    // working on the seized device. These pages don't run through
    // tap-hold or the colon-form remap table — they're pass-through
    // only.
    if (ev.usage_page != 0x07) {
        cx.skipped_other_pages += 1;
        const usage16 = std.math.cast(u16, ev.usage) orelse return;
        switch (ev.usage_page) {
            0x0C => {
                if (!cx.consumer_state.apply(usage16, ev.pressed)) return;
                cx.vhidd.postConsumerReport(cx.consumer_state.compacted()) catch |err| {
                    log.warn("vhidd consumer post failed: {s}", .{@errorName(err)});
                };
            },
            0xFF => {
                if (!cx.apple_top_case_state.apply(usage16, ev.pressed)) return;
                cx.vhidd.postAppleVendorTopCaseReport(cx.apple_top_case_state.compacted()) catch |err| {
                    log.warn("vhidd apple-top-case post failed: {s}", .{@errorName(err)});
                };
            },
            0xFF01 => {
                if (!cx.apple_keyboard_state.apply(usage16, ev.pressed)) return;
                cx.vhidd.postAppleVendorKeyboardReport(cx.apple_keyboard_state.compacted()) catch |err| {
                    log.warn("vhidd apple-keyboard post failed: {s}", .{@errorName(err)});
                };
            },
            else => {}, // unknown page; ignore
        }
        return;
    }

    // Guard the truncation: HID 0x07 usages in normal use are
    // 0x04..0xE7, but the kernel emits the keys[] array element
    // itself with a sentinel usage (0xFFFFFFFF) carrying the
    // per-slot value, plus status codes 0x00..0x03 (no event /
    // ErrorRollOver / POSTFail / ErrorUndefined). None of those
    // should drive our state machine.
    const raw_usage16 = std.math.cast(u16, ev.usage) orelse return;
    if (raw_usage16 < 0x04) return;

    // F1..F12 on Apple's built-in keyboard need translation. Seizing
    // the keyboard service silences the OS's apple-vendor media-key
    // path for that device, so we have to do the F-row → media
    // translation ourselves and post through vhidd's consumer /
    // apple-vendor / generic-desktop reports. Mirrors Karabiner's
    // `fn_function_keys_manipulator` default mapping.
    //
    // Policy follows NSGlobalDomain `com.apple.keyboard.fnState`
    // ("Use F1, F2 … as standard function keys"), forwarded to us by
    // the agent so we don't have to do a per-uid prefs read from a
    // root daemon:
    //   pref OFF (default): bare F<i> → media, fn+F<i> → literal F<i>
    //   pref ON:            bare F<i> → literal F<i>, fn+F<i> → media
    //
    // We read fn-state from our own `apple_top_case_state` rather than
    // `CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState)`
    // because the latter is polluted by our own vhidd forwards: every
    // fn we round-trip through vhidd is reflected back into the OS HID
    // flags, so the query stops being a clean "is the user holding
    // fn?" signal. The internal page-state, by contrast, only tracks
    // events from the seized device — same source the rest of seize
    // uses, so the F-row decision stays self-consistent.
    if (raw_usage16 >= 0x3A and raw_usage16 <= 0x45) {
        const fn_held = blk: for (cx.apple_top_case_state.keys) |k| {
            if (k == 0x03) break :blk true;
        } else false;
        const want_media = if (cx.fkeys_as_standard) fn_held else !fn_held;
        if (want_media) {
            translateFRow(cx, raw_usage16, ev.pressed);
            return;
        }
        // else fall through to keyboard-page emit (literal F-key).
    }

    // Apply colon-form `.remap` rewrites BEFORE the slots see the
    // event — hidutil's UserKeyMapping doesn't reach seized devices
    // (kIOHIDOptionsTypeSeizeDevice bypasses the IOHIDLib filter
    // chain), so the grabber has to do the substitution itself.
    const usage16: u16 = blk: {
        if (raw_usage16 < cx.remap_table.len) {
            const dst = cx.remap_table[raw_usage16];
            if (dst != 0) break :blk dst;
        }
        break :blk raw_usage16;
    };

    const taphold_event: TapHold.Event = .{
        .usage_page = 0x07,
        .usage = usage16,
        .pressed = ev.pressed,
    };

    // If this event is the source of some slot's tap-hold rule,
    // only deliver it to that slot — never to other slots. Letting
    // a foreign slot buffer a fellow source leads to double-emit
    // pathologies: user presses caps+space, caps_slot (still
    // pending) snapshots space-down into its buffer, and on caps's
    // hold-commit replays space-down to the OS, which then sees
    // space held under ctrl and autorepeats.
    //
    // The check has to be "is this any slot's source?", not "is
    // this a *currently-pending* slot's source?": at the moment
    // space-down arrives, space_slot hasn't yet transitioned to
    // pending (this event is what triggers it), so the pending-
    // state-filtered version of the check would miss this case.
    const event_is_some_slot_source = blk: for (cx.slots) |*slot| {
        if (slot.engine.rule.src_usage == usage16) break :blk true;
    } else false;

    var any_consumed = false;
    for (cx.slots) |*slot| {
        if (event_is_some_slot_source and slot.engine.rule.src_usage != usage16) {
            continue;
        }
        const r = slot.engine.feed(taphold_event);
        applyTapHoldTimer(slot, r.timer);
        if (r.disposition == .consumed) any_consumed = true;
    }

    // Apple firmware caps_lock neutralization. The proper fix
    // (HIDKeyboardCapsLockDelayOverride=0 via IOHIDServiceClient or
    // IOHIDSetModifierLockState) is gated on a real Apple Developer
    // ID signature — both fail silently on self-signed binaries.
    // Fallback: read the OS-level caps_lock state via the still-open
    // CGEventSource API and, if Apple's firmware has toggled it,
    // inject a vhidd caps_lock toggle to flip it back. Visible as a
    // brief LED flash on long holds; clean otherwise.
    if (usage16 == 0x39 and cx.caps_remap_active) {
        if (cx.hidsystem) |*hs| hs.setCapsLockState(false); // no-op when unsigned
        const flags = c.CGEventSourceFlagsState(c.kCGEventSourceStateHIDSystemState);
        if ((flags & c.kCGEventFlagMaskAlphaShift) != 0) {
            log.info("caps_lock toggled by firmware — injecting vhidd toggle to flip off", .{});
            // Apply the toggle to KbState so the next vhidd report
            // reflects it correctly, then post.
            _ = cx.state.applyKeyboardEvent(0x39, true);
            cx.vhidd.postKeyboardReport(cx.state.modifiers, cx.state.compactedKeys()) catch {};
            _ = cx.state.applyKeyboardEvent(0x39, false);
            cx.vhidd.postKeyboardReport(cx.state.modifiers, cx.state.compactedKeys()) catch {};
        }
    }

    if (any_consumed) return;

    emitToVhidd(@ptrCast(cx), taphold_event);
}

/// Open the vhidd virtual keyboard, seize the matched physical
/// keyboard, run the CFRunLoop with everything-passes-through for
/// `duration_ms`, then release. Used to verify D3 end-to-end before
/// any rules are wired up.
fn seizeTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    match: HidSeize.Match,
    duration_ms: u32,
    mode: HidSeize.Mode,
    rule: ?TapHold.Rule,
    profile: bool,
) !void {
    log.info("seize-test: device 0x{X:0>4}:0x{X:0>4} for {d}ms (mode={s})", .{
        match.vendor,
        match.product,
        duration_ms,
        @tagName(mode),
    });
    if (rule) |r| {
        const hold_str: []const u8 = switch (r.hold) {
            .hid_usage => "<hid_usage>",
            .layer => |n| n,
        };
        log.info(
            "  taphold rule: src=0x{X:0>2} tap=0x{X:0>2} hold={s} timeout={d}ms perm={} hokp={}",
            .{ r.src_usage, r.tap_usage, hold_str, r.timeout_ms, r.permissive_hold, r.hold_on_other_key_press },
        );
    }

    if (c.geteuid() != 0) {
        log.err("seize-test needs root (sudo)", .{});
        return error.NotPrivileged;
    }

    log.info("connecting to vhidd_server", .{});
    var vhidd = try Vhidd.Client.connect(allocator, io);
    defer vhidd.close();

    log.info("initializing virtual keyboard", .{});
    try vhidd.initializeKeyboard(.{});
    try vhidd.waitForBoolTrue(.virtual_hid_keyboard_ready, 5000);
    log.info("virtual keyboard ready", .{});

    var ctx = SeizeCtx{
        .state = .{},
        .vhidd = &vhidd,
        .hidsystem = HidSystem.init() catch |err| blk: {
            log.warn("IOHIDSystem connect failed ({s}); caps_lock force-off skipped", .{@errorName(err)});
            break :blk null;
        },
        .profile = profile,
        .profile_timer = if (comptime profile_supported)
            (if (profile) ProfileTimer.start(io) else undefined)
        else
            undefined,
    };
    defer if (ctx.hidsystem) |*h| h.deinit();

    // Single inline rule for --seize-test. The slot must outlive the
    // run loop, so we keep it on the stack and slice into it.
    var slot_storage: [1]EngineSlot = undefined;
    if (rule) |r| {
        slot_storage[0] = .{
            .seize_ctx = &ctx,
            .engine = TapHold.init(r, emitToVhidd, &ctx),
        };
        ctx.slots = slot_storage[0..1];
        if (r.src_usage == 0x39) ctx.caps_remap_active = true;
    }
    defer for (ctx.slots) |*s| cancelTapHoldTimer(s);

    var seize = try HidSeize.init(allocator, seizeInputCallback, &ctx);
    defer seize.deinit();
    try seize.setMatches(&.{match});
    try seize.start(mode);

    // Schedule a timer on the same run loop so we exit on duration.
    var timer_ctx = TimerCtx{};
    const timer = makeTimer(duration_ms, &timer_ctx);
    defer c.CFRelease(timer);
    c.CFRunLoopAddTimer(c.CFRunLoopGetCurrent(), timer, c.kCFRunLoopDefaultMode);

    log.info("seize active — typing on the seized keyboard should still work via vhidd pass-through", .{});

    // CFRunLoopRunInMode returns kCFRunLoopRunStopped when the timer
    // calls CFRunLoopStop. We loop in case of spurious wake-ups.
    while (!timer_ctx.stop) {
        const r = c.CFRunLoopRunInMode(c.kCFRunLoopDefaultMode, 60.0, 0);
        switch (r) {
            c.kCFRunLoopRunStopped, c.kCFRunLoopRunFinished => break,
            else => {},
        }
    }

    seize.stop();

    // Belt-and-braces: post an empty report to drop any virtual keys
    // we left held when the test ended (e.g. user kept the source
    // key pressed through the timeout, which committed hold but
    // never saw the corresponding source-up to emit hold-up).
    vhidd.postKeyboardReport(.{}, &.{}) catch {};

    log.info("seize-test done — events forwarded={d} other-pages-skipped={d}", .{
        ctx.forwarded,
        ctx.skipped_other_pages,
    });
}

const TimerCtx = struct {
    stop: bool = false,
};

fn timerCallback(_: c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const ctx: *TimerCtx = @ptrCast(@alignCast(info orelse return));
    ctx.stop = true;
    c.CFRunLoopStop(c.CFRunLoopGetCurrent());
}

fn makeTimer(after_ms: u32, ctx: *TimerCtx) c.CFRunLoopTimerRef {
    const fire_date = c.CFAbsoluteTimeGetCurrent() + @as(f64, @floatFromInt(after_ms)) / 1000.0;
    var context: c.CFRunLoopTimerContext = .{
        .version = 0,
        .info = ctx,
        .retain = null,
        .release = null,
        .copyDescription = null,
    };
    return c.CFRunLoopTimerCreate(
        c.kCFAllocatorDefault,
        fire_date,
        0,
        0,
        0,
        timerCallback,
        &context,
    );
}

/// Parse a tap-hold rule of the form `SRC:TAP:HOLD[@TIMEOUT_MS]`.
/// Each usage may be hex (0x...) or decimal. Timeout defaults to
/// 200ms if omitted. Modifier flags (--permissive-hold etc.) are
/// applied separately by the CLI parser after this returns.
fn parseRule(s: []const u8) !TapHold.Rule {
    const at_pos = std.mem.indexOfScalar(u8, s, '@');
    const usages_part = if (at_pos) |p| s[0..p] else s;
    const timeout_part = if (at_pos) |p| s[p + 1 ..] else "";

    var it = std.mem.splitScalar(u8, usages_part, ':');
    const src_s = it.next() orelse return error.MissingSource;
    const tap_s = it.next() orelse return error.MissingTap;
    const hold_s = it.next() orelse return error.MissingHold;
    if (it.next() != null) return error.TooManyParts;

    const src = try parseHexOrDec(src_s);
    const tap = try parseHexOrDec(tap_s);
    const hold = try parseHexOrDec(hold_s);

    const timeout: u32 = if (timeout_part.len > 0) try parseHexOrDec(timeout_part) else 200;

    return .{
        .src_usage = std.math.cast(u16, src) orelse return error.SourceUsageOverflow,
        .tap_usage = std.math.cast(u16, tap) orelse return error.TapUsageOverflow,
        .hold = .{ .hid_usage = std.math.cast(u16, hold) orelse return error.HoldUsageOverflow },
        .timeout_ms = timeout,
    };
}

fn parseVendorProduct(s: []const u8) ![2]u32 {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return error.MissingColon;
    const vendor = try parseHexOrDec(s[0..colon]);
    const product = try parseHexOrDec(s[colon + 1 ..]);
    return .{ vendor, product };
}

fn parseHexOrDec(s: []const u8) !u32 {
    if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X")) {
        return std.fmt.parseInt(u32, s[2..], 16);
    }
    return std.fmt.parseInt(u32, s, 10);
}

fn printHelp() void {
    std.debug.print(
        \\skhd-grabber - system daemon for caps-class tap-hold remaps
        \\
        \\Usage: skhd-grabber [options]
        \\
        \\Options:
        \\  --socket-path <path>   Override IPC socket path
        \\                         (default: /var/run/skhd/grabber.sock)
        \\  --foreground           Run in foreground (logs to stderr)
        \\  -v, --version          Print version
        \\  -h, --help             Show this help
        \\
        \\Debug:
        \\  --inject-test-key      Connect to Karabiner vhidd_server, init the
        \\                         virtual keyboard, send a single Escape
        \\                         keydown/up. Verifies the D2 injection path.
        \\  --seize-test V:P       Seize keyboard with vendor V product P (hex
        \\                         like 0x05AC:0x0342) and pass every keyboard
        \\                         event through vhidd unchanged. Auto-releases
        \\                         after --seize-test-duration seconds (default
        \\                         30). Verifies the D3 seize+pass-through path.
        \\  --seize-test-observe   Run --seize-test in passive observe mode
        \\                         (kernel still receives the events too) for
        \\                         diagnostics.
        \\  --seize-test-duration N
        \\                         Seconds before --seize-test auto-releases.
        \\  --rule SRC:TAP:HOLD[@TIMEOUT_MS]
        \\                         Add one tap-hold rule active during
        \\                         --seize-test. Usages are HID page-7 codes
        \\                         (e.g. 0x39 caps_lock, 0x29 escape, 0xE0
        \\                         lctrl). Timeout defaults to 200ms.
        \\  --permissive-hold      Tweak --rule's tap-hold semantics (QMK
        \\                         permissive_hold).
        \\  --hold-on-other-key-press
        \\                         Tweak --rule's tap-hold semantics (QMK
        \\                         hold_on_other_key_press).
        \\  -P, --profile          Emit one stderr line per HID-in /
        \\                         timer-sched / timer-fire / vhidd-post
        \\                         boundary, with monotonic timestamps in
        \\                         microseconds and timer drift. Use it
        \\                         to investigate cold-start lag.
        \\                         Debug + ReleaseSafe builds only;
        \\                         compiled out of ReleaseFast / Small.
        \\
        \\This daemon is normally started by launchd via
        \\  /Library/LaunchDaemons/com.jackielii.skhd.grabber.plist
        \\Install it with: skhd --install-grabber
        \\
    , .{});
}
