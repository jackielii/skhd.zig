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

pub fn grabberStatus(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    var client = Client.connect(allocator, socket_path) catch |err| {
        std.debug.print(
            \\skhd-grabber: not reachable at {s} ({s})
            \\Install with: sudo skhd --install-grabber
            \\
        , .{ socket_path, @errorName(err) });
        return err;
    };
    defer client.close();

    try client.hello();
    // No way to query rule state yet — D5 will add `status` request type.
    // For now, a successful hello+bye is the heartbeat.
    try client.bye();
    std.debug.print("skhd-grabber: reachable at {s}, protocol v{d}\n", .{ socket_path, protocol.protocol_version });
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
