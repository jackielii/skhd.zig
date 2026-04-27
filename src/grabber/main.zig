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

const protocol = @import("grabber_protocol");
const Ipc = @import("Ipc.zig");
const RuleSet = @import("RuleSet.zig");
const Vhidd = @import("Vhidd.zig");

const log = std.log.scoped(.grabber);

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

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        _ = debug_allocator.deinit();
    };
    const gpa = switch (builtin.mode) {
        .Debug, .ReleaseSafe => debug_allocator.allocator(),
        .ReleaseFast, .ReleaseSmall => std.heap.smp_allocator,
    };

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var socket_path: []const u8 = protocol.default_socket_path;

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
            injectTestKey(gpa) catch |err| {
                log.err("inject-test-key failed: {s}", .{@errorName(err)});
                std.process.exit(1);
            };
            return;
        } else {
            std.debug.print("error: unknown argument: {s}\n", .{a});
            std.process.exit(2);
        }
    }

    log.info("skhd-grabber starting (socket={s}, pid={d})", .{ socket_path, std.c.getpid() });

    try ensureSocketParentDir(socket_path);
    // Stale socket from a crashed previous run: bind() would EADDRINUSE.
    posix.unlink(socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    var addr = try std.net.Address.initUnix(socket_path);
    var server = try addr.listen(.{ .reuse_address = false });
    defer server.deinit();
    bound_socket_path = socket_path;
    defer {
        posix.unlink(socket_path) catch {};
        bound_socket_path = null;
    }

    // World-writable so any logged-in user's agent can connect. D5 will
    // tighten this when per-uid auth lands; for D1 the protocol carries
    // uid in the hello and we trust it.
    chmodPath(socket_path, 0o666) catch |err| {
        log.warn("chmod {s} failed: {s}", .{ socket_path, @errorName(err) });
    };

    installSignalHandlers();

    var ruleset = RuleSet.init(gpa);
    defer ruleset.deinit();

    log.info("listening on {s}", .{socket_path});

    while (!should_exit.load(.acquire)) {
        const conn = server.accept() catch |err| switch (err) {
            // Interrupted by signal: re-check should_exit and either loop
            // around to a clean shutdown or keep listening.
            error.ConnectionAborted, error.SocketNotListening => break,
            else => {
                log.warn("accept failed: {s}", .{@errorName(err)});
                continue;
            },
        };
        defer conn.stream.close();

        Ipc.serve(gpa, conn.stream, &ruleset) catch |err| {
            log.warn("client session ended: {s}", .{@errorName(err)});
        };
    }

    log.info("shutting down", .{});
}

fn ensureSocketParentDir(socket_path: []const u8) !void {
    const dir = std.fs.path.dirname(socket_path) orelse return;
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
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
        .mask = posix.empty_sigset,
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &act, null);
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.HUP, &act, null);
    // SIGPIPE: client dropped mid-write; we want EPIPE from write() and
    // graceful continue, not whole-process termination.
    var ignore: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.empty_sigset,
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &ignore, null);
}

fn handleSignal(_: c_int) callconv(.C) void {
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
fn injectTestKey(allocator: std.mem.Allocator) !void {
    log.info("connecting to vhidd_server…", .{});
    var client = try Vhidd.Client.connect(allocator);
    defer client.close();

    log.info("initializing virtual keyboard…", .{});
    try client.initializeKeyboard(.{});

    log.info("waiting for virtual_hid_keyboard_ready=true…", .{});
    try client.waitForBoolTrue(.virtual_hid_keyboard_ready, 5000);
    log.info("keyboard ready", .{});

    // Brief settle; in practice the ready signal is enough but Apple
    // Silicon DriverKit sometimes needs a beat before injection lands
    // reliably (matches the example client's 100ms post-ready sleep).
    std.time.sleep(100 * std.time.ns_per_ms);

    // 'a' (HID 0x04). Picked over Escape because Escape is invisible in
    // most terminals — 'a' shows up on screen so injection success is
    // self-evident. The test only proves the wire path; the choice of
    // key is irrelevant.
    const test_usage: u16 = 0x04;
    log.info("posting keydown (a, HID 0x{X:0>2})", .{test_usage});
    try client.postKeyboardReport(.{}, &.{test_usage});

    std.time.sleep(50 * std.time.ns_per_ms);

    log.info("posting keyup (empty)", .{});
    try client.postKeyboardReport(.{}, &.{});

    // Small post-write grace period before close so the kernel has
    // time to deliver our final keyup before we tear the socket down.
    std.time.sleep(50 * std.time.ns_per_ms);
    log.info("done", .{});
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
        \\
        \\This daemon is normally started by launchd via
        \\  /Library/LaunchDaemons/com.jackielii.skhd.grabber.plist
        \\Install it with: skhd --install-grabber
        \\
    , .{});
}
