//! CLI subcommands that touch the system-grabber daemon.
//!
//! Implementations of `--install-grabber`, `--uninstall-grabber`,
//! `--grabber-status`, and `--grabber-test-rule`. Kept in their own
//! file so main.zig stays thin.

const std = @import("std");
const builtin = @import("builtin");

const c = @import("c.zig");
const protocol = @import("grabber_protocol");
const Client = @import("agent_grabber_client.zig").Client;

const log = std.log.scoped(.grabber_cli);

const install_script_rel = "scripts/install-grabber.sh";
const uninstall_script_rel = "scripts/uninstall-grabber.sh";
const grabber_binary_rel = "zig-out/bin/skhd-grabber";

/// Path to the installed grabber binary, used by --install-grabber to
/// know what to copy. We resolve it relative to the running skhd
/// binary's directory so a Homebrew install picks up the bundled copy
/// in libexec/, while a `zig build run` picks up zig-out/bin/.
fn resolveGrabberBinary(allocator: std.mem.Allocator) ![]const u8 {
    const self_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_path);

    // Try a sibling `skhd-grabber` next to ourselves first; that
    // covers both bundled installs (libexec/) and dev runs (zig-out/bin/).
    const dir = std.fs.path.dirname(self_path) orelse ".";
    const sibling = try std.fs.path.join(allocator, &.{ dir, "skhd-grabber" });
    if (fileExists(sibling)) return sibling;
    allocator.free(sibling);

    // Fallback: cwd-relative dev path so a `--install-grabber` invoked
    // from the repo root works even if the agent itself was launched
    // from elsewhere.
    const dev = try allocator.dupe(u8, grabber_binary_rel);
    if (fileExists(dev)) return dev;
    allocator.free(dev);

    return error.GrabberBinaryNotFound;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Resolve the absolute path to a script in the repo's scripts/
/// directory. Used by install/uninstall, both of which shell out to
/// bash.
fn resolveScript(allocator: std.mem.Allocator, rel: []const u8) ![]const u8 {
    // Two candidate roots: cwd (dev runs from the repo) and the dir
    // alongside the binary (bundled installs may carry scripts in a
    // sibling resources dir; for now we just look in the repo).
    if (fileExists(rel)) {
        return std.fs.realpathAlloc(allocator, rel) catch try allocator.dupe(u8, rel);
    }
    return error.ScriptNotFound;
}

pub fn installGrabber(allocator: std.mem.Allocator) !void {
    // Pre-check: the dext is what makes vhidd injection possible.
    // Without it, the grabber starts but its first connect attempt to the
    // vhidd_server fails. Branch on the specific failure mode so the user
    // gets actionable guidance (install pkg vs. reinstall pkg vs.
    // kickstart) rather than a generic "something's missing".
    const hid_state = try checkHidDaemonState(allocator);
    if (hid_state != .running) {
        printHidDaemonRemediation(hid_state);
        return switch (hid_state) {
            .not_installed => error.DextMissing,
            .plist_unregistered, .stopped => error.VhiddDaemonMissing,
            .running => unreachable,
        };
    }
    if (isKarabinerElementsActive(allocator)) {
        std.debug.print(
            \\warning: Karabiner-Elements is running and will conflict with
            \\skhd-grabber for HID seize. Disable Karabiner-Elements (or
            \\uninstall it) before relying on skhd-grabber's tap-hold/remap
            \\rules; otherwise both will fight for keyboard control.
            \\
        , .{});
    }

    const script = resolveScript(allocator, install_script_rel) catch {
        std.debug.print(
            "error: {s} not found. Run --install-grabber from the repo root.\n",
            .{install_script_rel},
        );
        return error.ScriptNotFound;
    };
    defer allocator.free(script);

    const binary = resolveGrabberBinary(allocator) catch {
        std.debug.print(
            "error: skhd-grabber binary not found. Run 'zig build' first.\n",
            .{},
        );
        return error.GrabberBinaryNotFound;
    };
    defer allocator.free(binary);

    const binary_abs = std.fs.realpathAlloc(allocator, binary) catch try allocator.dupe(u8, binary);
    defer allocator.free(binary_abs);

    if (c.geteuid() != 0) {
        std.debug.print(
            \\skhd --install-grabber needs root.
            \\Re-run with: sudo {s} {s}
            \\
        , .{ script, binary_abs });
        return error.NotRoot;
    }

    var child = std.process.Child.init(&.{ "/bin/bash", script, binary_abs }, allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    if (term != .Exited or term.Exited != 0) return error.InstallFailed;

    // Tahoe TCC quirk: IOHIDManager seize needs Input Monitoring,
    // and the launchd-managed binary doesn't trigger the approval
    // dialog on its own. The user has to add the binary to the
    // Input Monitoring list by hand the first time.
    std.debug.print(
        \\
        \\Next step: grant Input Monitoring to the grabber binary.
        \\
        \\1. Open System Settings > Privacy & Security > Input Monitoring.
        \\2. Click '+' and add: /usr/local/libexec/skhd-grabber
        \\3. Toggle the entry on.
        \\4. Re-kick the daemon so it picks up the grant:
        \\     sudo launchctl kickstart -k system/com.jackielii.skhd.grabber
        \\
        \\Verify with:  skhd --grabber-status
        \\
    , .{});
}

/// Path of the system LaunchDaemon plist installed by the
/// `--install-grabber` flow. If this file exists, the grabber is
/// already registered with launchd (whether currently running or not).
const grabber_plist_path = "/Library/LaunchDaemons/com.jackielii.skhd.grabber.plist";

/// True when the grabber LaunchDaemon plist is installed. Used by
/// the smart `--install-service` flow to skip the sudo prompt for
/// users who already installed the grabber separately.
pub fn isGrabberInstalled() bool {
    std.fs.accessAbsolute(grabber_plist_path, .{}) catch return false;
    return true;
}

/// Re-exec ourselves under sudo with `--install-grabber`. Sudo
/// prompts the user for their password inline (stdio is inherited),
/// so this only works in an interactive terminal context. Returns an
/// error if sudo or the install fails — caller logs and tells the
/// user how to retry by hand.
pub fn installGrabberViaSudo(allocator: std.mem.Allocator) !void {
    const self_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_path);

    var child = std.process.Child.init(&.{ "/usr/bin/sudo", self_path, "--install-grabber" }, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    if (term != .Exited or term.Exited != 0) return error.GrabberInstallFailed;
}

pub fn uninstallGrabber(allocator: std.mem.Allocator) !void {
    const script = resolveScript(allocator, uninstall_script_rel) catch {
        std.debug.print(
            "error: {s} not found. Run --uninstall-grabber from the repo root.\n",
            .{uninstall_script_rel},
        );
        return error.ScriptNotFound;
    };
    defer allocator.free(script);

    if (c.geteuid() != 0) {
        std.debug.print(
            \\skhd --uninstall-grabber needs root.
            \\Re-run with: sudo {s}
            \\
        , .{script});
        return error.NotRoot;
    }

    var child = std.process.Child.init(&.{ "/bin/bash", script }, allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    if (term != .Exited or term.Exited != 0) return error.UninstallFailed;
}

/// Walk every prerequisite for caps_lock-class tap-hold and report
/// where the chain breaks. One command users can run when something
/// isn't working — gives a clear "this is where it's broken, this is
/// how to fix it" without them having to know the layered design.
pub fn grabberStatus(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    std.debug.print("skhd-grabber status\n", .{});
    std.debug.print("===================\n\n", .{});

    var ok_count: u32 = 0;
    var fail_count: u32 = 0;

    // 1. Karabiner DriverKit dext (provides the virtual HID device
    //    that the grabber injects through). Loaded dext shows up as
    //    a running process under _driverkit owned by launchd.
    if (try processRunning(allocator, "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice")) {
        std.debug.print("  [OK]      Karabiner-DriverKit-VirtualHIDDevice (dext) loaded\n", .{});
        ok_count += 1;
    } else {
        std.debug.print(
            \\  [MISSING] Karabiner-DriverKit-VirtualHIDDevice (dext) not loaded
            \\            Required for HID injection. Install from
            \\              https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice
            \\            Then approve it in System Settings > Privacy & Security.
            \\
        , .{});
        fail_count += 1;
    }

    // 2. Karabiner-VirtualHIDDevice-Daemon (userland helper that
    //    bridges our IPC to the dext). It's the process we connect
    //    to via vhidd_server socket.
    if (try processRunning(allocator, "Karabiner-VirtualHIDDevice-Daemon")) {
        std.debug.print("  [OK]      Karabiner-VirtualHIDDevice-Daemon running\n", .{});
        ok_count += 1;
    } else {
        std.debug.print(
            \\  [MISSING] Karabiner-VirtualHIDDevice-Daemon not running
            \\            Comes with the dext install. Try:
            \\              sudo launchctl kickstart -k system/org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon
            \\
        , .{});
        fail_count += 1;
    }

    // 3. skhd-grabber LaunchDaemon plist (we installed it via
    //    --install-grabber).
    if (isGrabberInstalled()) {
        std.debug.print("  [OK]      skhd-grabber LaunchDaemon plist installed\n", .{});
        ok_count += 1;
    } else {
        std.debug.print(
            \\  [MISSING] skhd-grabber LaunchDaemon plist not found
            \\            Install with:
            \\              sudo skhd --install-grabber
            \\
        , .{});
        fail_count += 1;
    }

    // 4. skhd-grabber process running.
    if (try processRunning(allocator, "skhd-grabber")) {
        std.debug.print("  [OK]      skhd-grabber process running\n", .{});
        ok_count += 1;
    } else {
        std.debug.print(
            \\  [MISSING] skhd-grabber not running
            \\            Try:
            \\              sudo launchctl kickstart -k system/com.jackielii.skhd.grabber
            \\
        , .{});
        fail_count += 1;
    }

    // 5. IPC socket reachable + protocol version match.
    var client = Client.connect(allocator, socket_path) catch |err| {
        std.debug.print(
            \\  [FAIL]    IPC socket not reachable at {s} ({s})
            \\
            \\Summary: {d} OK, {d} failing — fix the [MISSING]/[FAIL] items above.
            \\
        , .{ socket_path, @errorName(err), ok_count, fail_count + 1 });
        return err;
    };
    defer client.close();
    client.hello() catch |err| {
        std.debug.print(
            \\  [FAIL]    IPC handshake failed ({s}) — protocol version mismatch?
            \\            agent expects v{d}; grabber may be older.
            \\
        , .{ @errorName(err), protocol.protocol_version });
        return err;
    };
    client.bye() catch {};
    std.debug.print("  [OK]      IPC socket reachable at {s} (protocol v{d})\n", .{ socket_path, protocol.protocol_version });
    ok_count += 1;

    if (fail_count == 0) {
        std.debug.print("\nSummary: {d} OK, 0 failing — everything looks good.\n", .{ok_count});
    } else {
        std.debug.print("\nSummary: {d} OK, {d} failing — fix the [MISSING] items above.\n", .{ ok_count, fail_count });
    }
}

/// True if at least one running process matches `needle` in its
/// argv. Uses pgrep so we don't need root for system-domain queries.
fn processRunning(allocator: std.mem.Allocator, needle: []const u8) !bool {
    var child = std.process.Child.init(&.{ "/usr/bin/pgrep", "-f", needle }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const term = try child.wait();
    return term == .Exited and term.Exited == 0;
}

/// Path to the daemon binary's Info.plist — single source of truth for the
/// installed Karabiner DriverKit version (matches what's in the dext).
const vhidd_info_plist = "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/Info.plist";

/// HID daemon dependency state, in priority order: missing dext → broken
/// launchd registration → just-stopped → running. Each state has a distinct
/// remediation so callers (--install-grabber, --status) can give specific
/// guidance instead of a generic "something's wrong".
pub const HidDaemonState = enum {
    /// The DriverKit dext isn't loaded. User needs to install the
    /// Karabiner-DriverKit-VirtualHIDDevice .pkg from pqrs releases.
    not_installed,
    /// Dext is loaded but the daemon binary's launchd plist isn't
    /// registered. Happens after a partial uninstall or when only the
    /// dext was installed without its companion plist. `kickstart` will
    /// fail with "could not find service"; need to re-run the .pkg
    /// installer.
    plist_unregistered,
    /// Dext loaded, daemon plist registered, daemon just isn't running.
    /// Recoverable via `launchctl kickstart`.
    stopped,
    /// All good.
    running,
};

const vhidd_launchd_label = "org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon";

/// Probe the HID daemon dependency chain and return the first failure
/// found, or `running` if every layer is up. The caller is expected to
/// branch on the result for state-specific messaging.
pub fn checkHidDaemonState(allocator: std.mem.Allocator) !HidDaemonState {
    const dext_loaded = try processRunning(allocator, "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice");
    if (!dext_loaded) return .not_installed;

    const daemon_running = try processRunning(allocator, "Karabiner-VirtualHIDDevice-Daemon");
    if (daemon_running) return .running;

    // Daemon process not running. Distinguish "launchd doesn't know about
    // it at all" (plist_unregistered, kickstart will fail) from "launchd
    // knows about it, just not running right now" (stopped, kickstart
    // works). `launchctl print system/<label>` returns non-zero with
    // "Could not find service" for the former.
    const registered = try launchdServiceRegistered(allocator);
    return if (registered) .stopped else .plist_unregistered;
}

fn launchdServiceRegistered(allocator: std.mem.Allocator) !bool {
    const target = "system/" ++ vhidd_launchd_label;
    var child = std.process.Child.init(&.{ "/bin/launchctl", "print", target }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const term = try child.wait();
    return term == .Exited and term.Exited == 0;
}

/// Read CFBundleShortVersionString from the daemon's Info.plist (which
/// matches the dext's version — they ship together). Returns null if the
/// file is absent or PlistBuddy fails. Caller frees.
pub fn readHidDaemonVersion(allocator: std.mem.Allocator) ?[]const u8 {
    var child = std.process.Child.init(
        &.{ "/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString", vhidd_info_plist },
        allocator,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;

    var buf: [128]u8 = undefined;
    var n: usize = 0;
    if (child.stdout) |stdout| {
        n = stdout.reader().read(&buf) catch 0;
    }
    const term = child.wait() catch return null;
    if (term != .Exited or term.Exited != 0) return null;

    const trimmed = std.mem.trim(u8, buf[0..n], " \r\n\t");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}

/// True iff Karabiner-Elements' userland grabber is currently running.
/// Coexists badly with skhd-grabber (both seize keyboards via the same
/// dext), so we surface this as a warning in --install-grabber and --status.
pub fn isKarabinerElementsActive(allocator: std.mem.Allocator) bool {
    return processRunning(allocator, "karabiner_grabber") catch false;
}

/// Print the one-line `--status` summary for the HID daemon. Returns the
/// detected state so the caller can decide whether to print the
/// remediation block below the existing remediation chain. Errors during
/// the probe are reported inline and treated as `.running` so we don't
/// spam an irrelevant remediation in unusual environments.
pub fn printHidDaemonStatus(allocator: std.mem.Allocator) HidDaemonState {
    const state = checkHidDaemonState(allocator) catch |err| {
        std.debug.print("  HID daemon:           Unknown ({s})\n", .{@errorName(err)});
        return .running;
    };

    const version = readHidDaemonVersion(allocator);
    defer if (version) |v| allocator.free(v);

    switch (state) {
        .running => {
            if (version) |v| {
                std.debug.print("  HID daemon:           Running (Karabiner DriverKit v{s})\n", .{v});
            } else {
                std.debug.print("  HID daemon:           Running\n", .{});
            }
        },
        .not_installed => std.debug.print("  HID daemon:           Not installed (required for .remap / .taphold rules)\n", .{}),
        .plist_unregistered => {
            const v_str = version orelse "?";
            std.debug.print("  HID daemon:           DEXT v{s} loaded but launchd entry missing\n", .{v_str});
        },
        .stopped => {
            const v_str = version orelse "?";
            std.debug.print("  HID daemon:           Stopped (Karabiner DriverKit v{s} installed)\n", .{v_str});
        },
    }

    if (isKarabinerElementsActive(allocator)) {
        std.debug.print("  Karabiner-Elements:   Active — conflicts with skhd-grabber for HID seize\n", .{});
    }

    return state;
}

/// Print state-specific remediation for a non-running HID daemon. Called
/// from the bottom of --status and from --install-grabber's preflight.
/// `--install-service` is the user-facing entry point; `--install-grabber`
/// is the privileged subcommand it invokes once prereqs are in place.
pub fn printHidDaemonRemediation(state: HidDaemonState) void {
    switch (state) {
        .running => {},
        .not_installed => std.debug.print(
            \\
            \\HID daemon (Karabiner-DriverKit-VirtualHIDDevice) is not installed.
            \\skhd-grabber injects HID events through this dext. Install it from:
            \\  https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases
            \\Approve the system extension in System Settings → Privacy &
            \\Security, then re-run:
            \\  skhd --install-service
            \\
        , .{}),
        .plist_unregistered => std.debug.print(
            \\
            \\HID daemon's launchd entry is missing — the dext loaded but the
            \\companion userland helper (Karabiner-VirtualHIDDevice-Daemon)
            \\never got registered with launchd. `launchctl kickstart` will
            \\fail with "could not find service" in this state.
            \\
            \\Reinstall Karabiner-DriverKit-VirtualHIDDevice (idempotent — the
            \\.pkg redoes the launchd registration cleanly):
            \\  https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases
            \\
        , .{}),
        .stopped => std.debug.print(
            \\
            \\HID daemon is stopped. Restart it with:
            \\  sudo launchctl kickstart -k system/org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon
            \\(skhd-grabber will reconnect automatically once it's back up.)
            \\
        , .{}),
    }
}

/// Send a hard-coded sample rule to the grabber so we can validate the
/// IPC plumbing end-to-end before parser integration lands. Logs at
/// the grabber side print the parsed rule.
pub fn grabberTestRule(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    const sample_rules = [_]protocol.Rule{
        .{
            .src_usage = 0x39, // caps_lock
            .tap_usage = 0x29, // escape
            .hold_usage = 0xE0, // left ctrl
            .device = .{ .vendor = 0x05AC, .product = 0x0342 },
            .timeout_ms = 200,
            .permissive_hold = true,
            .hold_on_other_key_press = false,
            .retro_tap = false,
        },
    };

    var client = try Client.connect(allocator, socket_path);
    defer client.close();

    try client.hello();
    try client.applyRules(&sample_rules, &.{});
    try client.bye();

    std.debug.print(
        "sent test rule (caps_lock → tap escape / hold lctrl) to {s}\n",
        .{socket_path},
    );
}
