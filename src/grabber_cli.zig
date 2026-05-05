//! CLI subcommands that touch the system-grabber daemon.
//!
//! Implementations of `--install-grabber`, `--uninstall-grabber`,
//! `--grabber-status`, and `--grabber-test-rule`. Kept in their own
//! file so main.zig stays thin.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const c = @import("c.zig");
const protocol = @import("grabber_protocol");
const Client = @import("agent_grabber_client.zig").Client;

/// The Karabiner-DriverKit-VirtualHIDDevice version skhd-grabber's IPC has
/// been validated against. Set in build.zig (`karabiner_dext_version`),
/// passed through `build_options`. Used as the source of truth for both
/// `zig build install-dext` and runtime compatibility checks.
pub const pinned_dext_version = build_options.karabiner_dext_version;

/// Result of comparing the installed dext version (`readHidDaemonVersion`)
/// against `pinned_dext_version`. The pqrs project follows SemVer and uses
/// the major as their compat boundary, so we treat any non-major-matching
/// install as incompatible — wire format may differ, IPC may break.
pub const Compatibility = enum {
    /// Same major version (or same exact version). IPC contract holds.
    ok,
    /// Installed major is older than pinned. User likely has an older
    /// Karabiner-Elements bundled DriverKit; IPC is not guaranteed.
    older,
    /// Installed major is newer than pinned. User upgraded the dext; we
    /// haven't validated against this version.
    newer,
    /// Either string failed to parse.
    parse_error,
};

fn parseMajor(version: []const u8) ?u32 {
    const dot = std.mem.indexOfScalar(u8, version, '.') orelse version.len;
    return std.fmt.parseInt(u32, version[0..dot], 10) catch null;
}

pub fn compareVersions(installed: []const u8, pinned: []const u8) Compatibility {
    const installed_major = parseMajor(installed) orelse return .parse_error;
    const pinned_major = parseMajor(pinned) orelse return .parse_error;
    if (installed_major == pinned_major) return .ok;
    if (installed_major < pinned_major) return .older;
    return .newer;
}

test "compareVersions: same major" {
    try std.testing.expectEqual(Compatibility.ok, compareVersions("6.14.0", "6.0.0"));
    try std.testing.expectEqual(Compatibility.ok, compareVersions("6.0.0", "6.0.0"));
    try std.testing.expectEqual(Compatibility.older, compareVersions("5.9.9", "6.0.0"));
    try std.testing.expectEqual(Compatibility.newer, compareVersions("7.0.0", "6.0.0"));
    try std.testing.expectEqual(Compatibility.parse_error, compareVersions("garbage", "6.0.0"));
}

const log = std.log.scoped(.grabber_cli);

const grabber_binary_rel = "zig-out/bin/skhd-grabber";

const grabber_launchd_label = "com.jackielii.skhd.grabber";
const grabber_plist_path = "/Library/LaunchDaemons/" ++ grabber_launchd_label ++ ".plist";

const grabber_socket_dir = "/var/run/skhd";
const grabber_socket_default = grabber_socket_dir ++ "/grabber.sock";

/// Path to the VHIDD daemon's launchd plist. installDext writes this so the
/// userland half of Karabiner-DriverKit-VirtualHIDDevice gets registered —
/// the standalone pqrs .pkg's postinstall is a no-op `killall` that assumes
/// some other component (Karabiner-Elements, historically) provides the
/// launchd entry. Without Karabiner-Elements, that entry never lands.
const vhidd_plist_path = "/Library/LaunchDaemons/" ++ vhidd_launchd_label ++ ".plist";

/// Embedded LaunchDaemon plist for `skhd-grabber`. Single source of truth
/// for the launchd config, baked into the skhd binary so `--install-grabber`
/// works from any cwd (and on a brew install where scripts/ isn't on disk).
/// Wired up as an anonymous import in build.zig (`addGrabberPlistImports`).
const grabber_plist_template = @embedFile("grabber_plist");

/// Embedded LaunchDaemon plist for `Karabiner-VirtualHIDDevice-Daemon`.
/// See the file's comment block for why we ship it.
const vhidd_plist_template = @embedFile("vhidd_plist");

/// Path to the installed grabber binary, used by --install-grabber to
/// know what to copy. We resolve it relative to the running skhd
/// binary's directory so a Homebrew install picks up the bundled copy
/// in libexec/, while a `zig build run` picks up zig-out/bin/.
fn resolveGrabberBinary(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const self_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_path);

    // Try a sibling `skhd-grabber` next to ourselves first; that
    // covers both bundled installs (libexec/) and dev runs (zig-out/bin/).
    const dir = std.fs.path.dirname(self_path) orelse ".";
    const sibling = try std.fs.path.join(allocator, &.{ dir, "skhd-grabber" });
    if (fileExists(io, sibling)) return sibling;
    allocator.free(sibling);

    // Fallback: cwd-relative dev path so a `--install-grabber` invoked
    // from the repo root works even if the agent itself was launched
    // from elsewhere.
    const dev = try allocator.dupe(u8, grabber_binary_rel);
    // dev is a relative path; resolve via cwd for the access check.
    if (std.Io.Dir.cwd().access(io, dev, .{})) |_| {
        return dev;
    } else |_| {}
    allocator.free(dev);

    return error.GrabberBinaryNotFound;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    } else {
        std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    }
    return true;
}

/// Run `/bin/launchctl <args...>`. Returns error on non-zero exit and
/// surfaces launchctl's stderr/stdout so the user can see *why* — without
/// this the caller's `catch {}` (or main.zig's `std.process.exit(1)`) leaves
/// the user staring at a half-finished install with no diagnostic at all.
fn runLaunchctl(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "/bin/launchctl");
    try argv.appendSlice(allocator, args);
    const result = std.process.run(allocator, io, .{ .argv = argv.items }) catch return error.LaunchctlFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exit_code: u32 = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };
    if (exit_code == 0) return;

    std.debug.print("launchctl", .{});
    for (args) |a| std.debug.print(" {s}", .{a});
    std.debug.print(" failed (exit {d})\n", .{exit_code});
    const out = std.mem.trim(u8, result.stdout, " \t\n\r");
    const err = std.mem.trim(u8, result.stderr, " \t\n\r");
    if (out.len > 0) std.debug.print("  stdout: {s}\n", .{out});
    if (err.len > 0) std.debug.print("  stderr: {s}\n", .{err});
    return error.LaunchctlFailed;
}

/// Create or overwrite an absolute path with `content`, mode 0644. Used
/// for system plists.
fn writePlistAbsolute(io: std.Io, path: []const u8, content: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .truncate = true,
        .permissions = .fromMode(0o644),
    });
    defer file.close(io);
    try file.setPermissions(io, .fromMode(0o644));
    try file.writeStreamingAll(io, content);
}

pub fn installGrabber(allocator: std.mem.Allocator, io: std.Io) !void {
    if (c.geteuid() != 0) {
        std.debug.print(
            \\skhd --install-grabber needs root.
            \\Re-run with: sudo skhd --install-grabber
            \\
        , .{});
        return error.NotRoot;
    }

    // Pre-check: the dext is what makes vhidd injection possible.
    // Without it, the grabber starts but its first connect attempt to the
    // vhidd_server fails. installDext now handles both `not_installed`
    // (no dext at all) and `plist_unregistered` (dext loaded but the
    // VHIDD launchd entry is missing — common after a partial Karabiner
    // uninstall) by re-running the .pkg + writing our shipped VHIDD plist.
    var hid_state = try checkHidDaemonState(allocator, io);
    if (hid_state == .not_installed or hid_state == .plist_unregistered) {
        std.debug.print(
            "\nKarabiner-DriverKit-VirtualHIDDevice setup needed (state: {s}). Installing pinned v{s}...\n",
            .{ @tagName(hid_state), pinned_dext_version },
        );
        try installDext(allocator, io);
        hid_state = try checkHidDaemonState(allocator, io);
    }
    if (hid_state != .running) {
        printHidDaemonRemediation(hid_state);
        return switch (hid_state) {
            .not_installed => error.DextMissing,
            .dext_disabled => error.DextDisabled,
            .plist_unregistered, .stopped => error.VhiddDaemonMissing,
            .running => unreachable,
        };
    }
    // Daemon is running — check the major version matches our pinned one.
    // Refuse on `.older` (IPC likely broken). `.newer` is allowed with a
    // warning; the user opted into a newer version explicitly.
    if (readHidDaemonVersion(allocator, io)) |installed_dext| {
        defer allocator.free(installed_dext);
        const compat = compareVersions(installed_dext, pinned_dext_version);
        if (compat == .older) {
            printVersionMismatchRemediation(installed_dext, compat);
            return error.DextVersionIncompatible;
        }
        if (compat == .newer) printVersionMismatchRemediation(installed_dext, compat);
    }
    if (isKarabinerElementsActive(allocator, io)) {
        std.debug.print(
            \\warning: Karabiner-Elements is running and will conflict with
            \\skhd-grabber for HID seize. Disable Karabiner-Elements (or
            \\uninstall it) before relying on skhd-grabber's tap-hold/remap
            \\rules; otherwise both will fight for keyboard control.
            \\
        , .{});
    }

    const binary = resolveGrabberBinary(allocator, io) catch {
        std.debug.print(
            \\error: skhd-grabber binary not found.
            \\Looked next to skhd at <bundle>/Contents/MacOS/skhd-grabber and
            \\at zig-out/bin/skhd-grabber. On a brew install, this means the
            \\bundled grabber is missing — try `brew reinstall skhd-zig`.
            \\
        , .{});
        return error.GrabberBinaryNotFound;
    };
    defer allocator.free(binary);

    const binary_abs = std.Io.Dir.cwd().realPathFileAlloc(io, binary, allocator) catch
        try allocator.dupeZ(u8, binary);
    defer allocator.free(binary_abs);

    // The plist's ProgramArguments path is critical for bundle-keyed TCC:
    // when the grabber runs from inside skhd.app, TCC walks up to the
    // bundle and uses the bundle ID (com.jackielii.skhd) — same client
    // identifier as the agent. A single Input Monitoring grant on
    // skhd.app then covers both processes. If the path resolves to a bare
    // binary outside any .app, TCC keys the grant by path+cdHash and the
    // user has to approve the daemon binary separately.
    const grabber_path_for_plist = grabber_path_for_plist: {
        if (std.mem.indexOf(u8, binary_abs, ".app/Contents/MacOS/") != null) {
            break :grabber_path_for_plist try allocator.dupe(u8, binary_abs);
        }
        std.debug.print(
            \\warning: grabber binary at {s} is not inside a .app bundle.
            \\TCC will key its Input Monitoring grant by path+cdHash, so the
            \\user has to add this path to System Settings manually and
            \\re-grant after every rebuild. For production installs run
            \\--install-grabber from a brew-installed bundle, or use
            \\`zig build install-local` to overlay into the bundle.
            \\
        , .{binary_abs});
        break :grabber_path_for_plist try allocator.dupe(u8, binary_abs);
    };
    defer allocator.free(grabber_path_for_plist);

    // 1. Render plist with the resolved grabber path.
    const rendered_plist = try renderGrabberPlist(allocator, grabber_path_for_plist);
    defer allocator.free(rendered_plist);

    // 2. Write the LaunchDaemon plist (no binary copy — we run the grabber
    //    in place from inside the bundle so TCC bundle-shares the grant).
    std.debug.print("Installing plist → {s} (program={s})\n", .{ grabber_plist_path, grabber_path_for_plist });
    try writePlistAbsolute(io, grabber_plist_path, rendered_plist);

    // 3. bootout-then-bootstrap so re-runs are idempotent.
    const target = "system/" ++ grabber_launchd_label;
    try bootstrapService(allocator, io, target, grabber_plist_path);

    // 4. Verify launchd actually has it registered. Catches the silent
    //    failure mode where bootstrap fails but the plist is on disk —
    //    `--grabber-status` would later report "[OK] plist installed"
    //    while `kickstart` fails with "Could not find service".
    if (!try launchdServiceRegistered(allocator, io, target)) {
        std.debug.print(
            \\
            \\error: skhd-grabber LaunchDaemon not registered with launchd
            \\despite the plist install. See launchctl errors above. Retry:
            \\  sudo skhd --install-grabber
            \\
        , .{});
        return error.GrabberRegistrationFailed;
    }

    // Brief pause for the daemon to bind its socket so a follow-up
    // --grabber-status reports "running" instead of "socket absent".
    std.Io.sleep(io, .fromMilliseconds(400), .awake) catch {};

    std.debug.print(
        \\
        \\Done. Daemon should now be running.
        \\Logs:    /var/log/skhd-grabber.log
        \\Socket:  {s}
        \\
        \\Input Monitoring permission: the agent (skhd) prompts for this on
        \\next launch. Granting it to skhd.app covers the grabber too —
        \\both binaries are signed with the same bundle ID and run from
        \\inside the bundle, so TCC bundle-shares the grant.
        \\
        \\Verify with:  skhd --grabber-status
        \\
    , .{grabber_socket_default});
}

/// Substitute every `__GRABBER_PATH__` placeholder in the embedded plist
/// template with the absolute path to the running bundle's grabber. This
/// is the path launchd will exec — picking the bundle path is what
/// enables bundle-keyed TCC. replaceAll (not first-match) so a stray
/// reference in the template's comment block doesn't shadow the one in
/// `<string>`, which would give launchd a literal `__GRABBER_PATH__`
/// program path and a cryptic EX_CONFIG (78) crash on bootstrap.
fn renderGrabberPlist(allocator: std.mem.Allocator, grabber_path: []const u8) ![]const u8 {
    const placeholder = "__GRABBER_PATH__";
    if (std.mem.indexOf(u8, grabber_plist_template, placeholder) == null) {
        std.debug.print(
            "internal error: grabber plist template missing __GRABBER_PATH__ placeholder\n",
            .{},
        );
        return error.PlistTemplateMalformed;
    }
    const out_size = std.mem.replacementSize(u8, grabber_plist_template, placeholder, grabber_path);
    const out = try allocator.alloc(u8, out_size);
    _ = std.mem.replace(u8, grabber_plist_template, placeholder, grabber_path, out);
    return out;
}

/// True when the grabber LaunchDaemon plist is installed. Used by
/// the smart `--install-service` flow to skip the sudo prompt for
/// users who already installed the grabber separately.
pub fn isGrabberInstalled(io: std.Io) bool {
    return fileExists(io, grabber_plist_path);
}

/// Re-exec ourselves under sudo with `--install-grabber`. Sudo
/// prompts the user for their password inline (stdio is inherited),
/// so this only works in an interactive terminal context. Returns an
/// error if sudo or the install fails — caller logs and tells the
/// user how to retry by hand.
pub fn installGrabberViaSudo(allocator: std.mem.Allocator, io: std.Io) !void {
    const self_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_path);

    var child = std.process.spawn(io, .{
        .argv = &.{ "/usr/bin/sudo", self_path, "--install-grabber" },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return error.GrabberInstallFailed;
    const term = child.wait(io) catch return error.GrabberInstallFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.GrabberInstallFailed,
        else => return error.GrabberInstallFailed,
    }
}

pub fn uninstallGrabber(allocator: std.mem.Allocator, io: std.Io) !void {
    if (c.geteuid() != 0) {
        std.debug.print(
            \\skhd --uninstall-grabber needs root.
            \\Re-run with: sudo skhd --uninstall-grabber
            \\
        , .{});
        return error.NotRoot;
    }

    // 1. skhd-grabber LaunchDaemon (always ours).
    const grabber_target = "system/" ++ grabber_launchd_label;
    if (fileExists(io, grabber_plist_path)) {
        std.debug.print("Stopping skhd-grabber...\n", .{});
        runLaunchctl(allocator, io, &.{ "bootout", grabber_target }) catch {};
        std.debug.print("Removing {s}\n", .{grabber_plist_path});
        std.Io.Dir.deleteFileAbsolute(io, grabber_plist_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return error.UnlinkFailed,
        };
    }

    // 2. VHIDD daemon LaunchDaemon — only ours if a file exists at this
    //    path. Karabiner-Elements registers via SMAppService and never
    //    writes to /Library/LaunchDaemons/, so the file's presence is a
    //    reliable signal that --install-dext put it there. Bootout first
    //    so a Karabiner install that follows can SMAppService-register
    //    against the same label without colliding.
    if (fileExists(io, vhidd_plist_path)) {
        const vhidd_target = "system/" ++ vhidd_launchd_label;
        std.debug.print("Stopping VHIDD daemon...\n", .{});
        runLaunchctl(allocator, io, &.{ "bootout", vhidd_target }) catch {};
        std.debug.print("Removing {s}\n", .{vhidd_plist_path});
        std.Io.Dir.deleteFileAbsolute(io, vhidd_plist_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return error.UnlinkFailed,
        };
    }

    // 3. Best-effort socket dir cleanup. Harmless if empty/missing.
    std.Io.Dir.deleteFileAbsolute(io, grabber_socket_default) catch {};
    std.Io.Dir.deleteDirAbsolute(io, grabber_socket_dir) catch {};

    std.debug.print(
        \\
        \\Done. Removed:
        \\  - skhd-grabber LaunchDaemon
        \\  - VHIDD daemon LaunchDaemon (if installed by --install-dext)
        \\
        \\Left in place:
        \\  - Karabiner-DriverKit-VirtualHIDDevice .pkg payload at
        \\    /Library/Application Support/org.pqrs/. Run pqrs's uninstall
        \\    scripts under .../scripts/uninstall/ to fully remove.
        \\  - The kernel-loaded dext (system extension; SIP gates removal
        \\    via systemextensionsctl — toggle off in System Settings →
        \\    Login Items & Extensions → Driver Extensions if you want it
        \\    gone).
        \\
    , .{});
}

/// Walk every prerequisite for caps_lock-class tap-hold and report
/// where the chain breaks. One command users can run when something
/// isn't working — gives a clear "this is where it's broken, this is
/// how to fix it" without them having to know the layered design.
pub fn grabberStatus(allocator: std.mem.Allocator, io: std.Io, socket_path: []const u8) !void {
    std.debug.print("skhd-grabber status\n", .{});
    std.debug.print("===================\n\n", .{});

    var ok_count: u32 = 0;
    var fail_count: u32 = 0;

    // 1. Karabiner DriverKit dext (provides the virtual HID device
    //    that the grabber injects through). Loaded dext shows up as
    //    a running process under _driverkit owned by launchd.
    //    Loaded-but-disabled (System Settings → Login Items & Extensions
    //    toggled off) is also a fail — the dext process keeps running so
    //    pgrep matches, but the kernel detaches it from HID dispatch.
    if (try processRunning(allocator, io, "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice")) {
        if (isDextEnabled(allocator, io)) |enabled| {
            if (enabled) {
                std.debug.print("  [OK]      Karabiner-DriverKit-VirtualHIDDevice (dext) loaded and enabled\n", .{});
                ok_count += 1;
            } else {
                std.debug.print(
                    \\  [FAIL]    Karabiner-DriverKit-VirtualHIDDevice (dext) loaded but DISABLED in System Settings
                    \\            Re-enable: System Settings → General → Login Items & Extensions →
                    \\            Driver Extensions → toggle Karabiner-VirtualHIDDevice Manager Extensions on.
                    \\
                , .{});
                fail_count += 1;
            }
        } else {
            // Probe failed (systemextensionsctl unavailable / output
            // unparseable). Don't false-alarm; trust the pgrep signal.
            std.debug.print("  [OK]      Karabiner-DriverKit-VirtualHIDDevice (dext) loaded (enabled-state probe inconclusive)\n", .{});
            ok_count += 1;
        }
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
    if (try processRunning(allocator, io, "Karabiner-VirtualHIDDevice-Daemon")) {
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
    if (isGrabberInstalled(io)) {
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
    if (try processRunning(allocator, io, "skhd-grabber")) {
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
    var client = Client.connect(allocator, io, socket_path) catch |err| {
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
        std.debug.print("\nSummary: {d} OK, {d} failing — fix the [MISSING]/[FAIL] items above.\n", .{ ok_count, fail_count });
    }
}

/// True if at least one running process matches `needle` in its
/// argv. Uses pgrep so we don't need root for system-domain queries.
fn processRunning(allocator: std.mem.Allocator, io: std.Io, needle: []const u8) !bool {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "/usr/bin/pgrep", "-f", needle },
    }) catch return error.SpawnFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Path to the daemon binary's Info.plist — single source of truth for the
/// installed Karabiner DriverKit version (matches what's in the dext).
const vhidd_info_plist = "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/Info.plist";

/// HID daemon dependency state, in priority order: missing dext →
/// dext-disabled → broken launchd registration → just-stopped →
/// running. Each state has a distinct remediation so callers
/// (--install-grabber, --status) can give specific guidance instead of
/// a generic "something's wrong".
pub const HidDaemonState = enum {
    /// The DriverKit dext isn't loaded. User needs to install the
    /// Karabiner-DriverKit-VirtualHIDDevice .pkg from pqrs releases.
    not_installed,
    /// Dext is loaded as a system extension but the user has toggled it
    /// off in System Settings → Login Items & Extensions → Driver
    /// Extensions. The dext process keeps running so a pgrep-only check
    /// reports it as loaded, but the kernel won't dispatch HID requests
    /// through it — vhidd injection silently no-ops and seize calls
    /// fail. Recovery is UI-only: SIP gates `systemextensionsctl
    /// activate` from the command line.
    dext_disabled,
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
pub fn checkHidDaemonState(allocator: std.mem.Allocator, io: std.Io) !HidDaemonState {
    const dext_loaded = try processRunning(allocator, io, "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice");
    if (!dext_loaded) return .not_installed;

    // The dext can be loaded-but-disabled — user toggled it off in
    // System Settings → Login Items & Extensions → Driver Extensions.
    // The dext process keeps running (so the pgrep above reports
    // "loaded") but the kernel detaches it from HID dispatch. Without
    // this check the status would lie: `--grabber-status` and
    // `--status` reported 5/5 OK while seize / injection silently
    // failed. `systemextensionsctl list` is the only programmatic
    // signal we have for this state.
    if (isDextEnabled(allocator, io)) |enabled| {
        if (!enabled) return .dext_disabled;
    }

    const daemon_running = try processRunning(allocator, io, "Karabiner-VirtualHIDDevice-Daemon");
    if (daemon_running) return .running;

    // Daemon process not running. Distinguish "launchd doesn't know about
    // it at all" (plist_unregistered, kickstart will fail) from "launchd
    // knows about it, just not running right now" (stopped, kickstart
    // works). `launchctl print system/<label>` returns non-zero with
    // "Could not find service" for the former.
    const registered = try launchdServiceRegistered(allocator, io, "system/" ++ vhidd_launchd_label);
    return if (registered) .stopped else .plist_unregistered;
}

/// Tri-state probe of the dext's enabled status via `systemextensionsctl
/// list`. Returns `true` only if the bundle's state line shows
/// `[activated enabled]`. Returns `false` for `[activated disabled]` or
/// any other recognized non-enabled state. Returns `null` when we can't
/// tell (command failed, output unparseable, bundle not in the list at
/// all) — caller treats that as "give the user the benefit of the doubt"
/// to avoid false alarms in unusual environments.
fn isDextEnabled(allocator: std.mem.Allocator, io: std.Io) ?bool {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "/usr/bin/systemextensionsctl", "list" },
        .stdout_limit = .limited(16 * 1024),
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    const dext_id = "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice";
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, dext_id) == null) continue;
        if (std.mem.indexOf(u8, line, "[activated enabled]") != null) return true;
        if (std.mem.indexOf(u8, line, "[activated disabled]") != null) return false;
        // Other states (`[deactivated]`, `[uninstalling]`, `[activated
        // waiting for user]`, …) — anything that isn't explicitly
        // `enabled` won't dispatch HID, so report as not-enabled.
        return false;
    }
    return null;
}


fn launchdServiceRegistered(allocator: std.mem.Allocator, io: std.Io, target: []const u8) !bool {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "/bin/launchctl", "print", target },
    }) catch return error.SpawnFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Atomically replace whatever launchd has registered at `target` with the
/// service in `plist_path`. macOS's `bootout` is asynchronous — the request
/// returns before teardown completes — so a follow-up `bootstrap` issued
/// immediately can fail with "Bootstrap failed: 5: Input/output error"
/// while the kernel is still releasing the prior registration. A short sleep
/// + one retry is the established workaround. After bootstrap we also
/// `enable` (clears any stale `disable` flag from a prior `unload -w`) and
/// `kickstart` (in case launchd opted to defer spawn). Caller is expected
/// to verify with `launchdServiceRegistered` after — bootstrap can still
/// fail in ways that warrant aborting the install.
fn bootstrapService(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: []const u8,
    plist_path: []const u8,
) !void {
    runLaunchctl(allocator, io, &.{ "bootout", target }) catch {};
    std.Io.sleep(io, .fromMilliseconds(300), .awake) catch {};
    runLaunchctl(allocator, io, &.{ "bootstrap", "system", plist_path }) catch {
        log.warn("bootstrap failed; retrying after 800ms (likely racing bootout teardown)", .{});
        std.Io.sleep(io, .fromMilliseconds(800), .awake) catch {};
        try runLaunchctl(allocator, io, &.{ "bootstrap", "system", plist_path });
    };
    runLaunchctl(allocator, io, &.{ "enable", target }) catch {};
    runLaunchctl(allocator, io, &.{ "kickstart", "-k", target }) catch {};
}

/// Read CFBundleShortVersionString from the daemon's Info.plist (which
/// matches the dext's version — they ship together). Returns null if the
/// file is absent or PlistBuddy fails. Caller frees.
pub fn readHidDaemonVersion(allocator: std.mem.Allocator, io: std.Io) ?[]const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString", vhidd_info_plist },
        .stdout_limit = .limited(128),
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \r\n\t");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}

/// True iff Karabiner-Elements' userland grabber is currently running.
/// Coexists badly with skhd-grabber (both seize keyboards via the same
/// dext), so we surface this as a warning in --install-grabber and --status.
pub fn isKarabinerElementsActive(allocator: std.mem.Allocator, io: std.Io) bool {
    return processRunning(allocator, io, "karabiner_grabber") catch false;
}

/// URL + SHA-256 for the pinned .pkg, exposed via build_options so the
/// same values flow to here and to `zig build install-dext`. Bumping
/// happens in build.zig — single source of truth, see the comment block
/// there.
const karabiner_dext_url = build_options.karabiner_dext_url;
const karabiner_dext_sha256 = build_options.karabiner_dext_sha256;

/// Resolve the cache path for the pinned .pkg. Per-version filename so
/// multiple versions don't collide; transient location (/tmp under root,
/// $XDG_CACHE_HOME or $HOME/.cache otherwise) since the .pkg is purely a
/// download cache, not configuration.
fn dextCachePath(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const filename = try std.fmt.allocPrint(allocator, "skhd-Karabiner-DriverKit-VirtualHIDDevice-{s}.pkg", .{pinned_dext_version});
    defer allocator.free(filename);

    if (c.geteuid() == 0) {
        // Running as root (typical when reached via `sudo skhd
        // --install-grabber`): /tmp is the safest writable location
        // that doesn't depend on a particular user's home.
        return std.fmt.allocPrint(allocator, "/tmp/{s}", .{filename});
    }

    const home = @import("utils.zig").getenv("HOME") orelse return error.NoHome;
    const dir = try std.fmt.allocPrint(allocator, "{s}/.cache/skhd", .{home});
    defer allocator.free(dir);
    std.Io.Dir.createDirAbsolute(io, dir, .fromMode(0o755)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.MkdirFailed,
    };
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, filename });
}

fn fileSha256(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    var read_buf: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &read_buf);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        const slice = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        hasher.update(slice);
        reader.interface.toss(slice.len);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);

    var hex_buf: [digest.len * 2]u8 = undefined;
    return allocator.dupe(u8, std.fmt.bufPrint(&hex_buf, "{x}", .{&digest}) catch unreachable);
}

/// Download + verify + install the pinned Karabiner-DriverKit-VirtualHIDDevice
/// .pkg. Idempotent: re-runs reuse the cached .pkg, and pqrs's installer is
/// a no-op when the same version is already installed. Re-execs via sudo
/// when not already root.
pub fn installDext(allocator: std.mem.Allocator, io: std.Io) !void {
    const pkg_path = try dextCachePath(allocator, io);
    defer allocator.free(pkg_path);

    // 1. Download to cache if missing.
    if (fileExists(io, pkg_path)) {
        std.debug.print("Using cached pkg at {s}\n", .{pkg_path});
    } else {
        std.debug.print("Downloading Karabiner-DriverKit-VirtualHIDDevice {s}...\n", .{pinned_dext_version});
        std.debug.print("  {s}\n", .{karabiner_dext_url});
        try runInherit(allocator, io, &.{ "/usr/bin/curl", "-fsSL", "-o", pkg_path, karabiner_dext_url }, error.DownloadFailed);
    }

    // 2. Verify sha256 against the pinned hash. On mismatch, drop the
    // cached file so the next attempt re-downloads — this protects
    // against a partial/corrupt download but won't auto-retry on what
    // could be a legitimate upstream re-tag (the user has to bump
    // build.zig in that case).
    const actual_hex = try fileSha256(allocator, io, pkg_path);
    defer allocator.free(actual_hex);
    if (!std.mem.eql(u8, actual_hex, karabiner_dext_sha256)) {
        std.debug.print(
            \\error: sha256 mismatch for {s}
            \\  expected: {s}
            \\  got:      {s}
            \\
        , .{ pkg_path, karabiner_dext_sha256, actual_hex });
        std.Io.Dir.deleteFileAbsolute(io, pkg_path) catch {};
        return error.Sha256Mismatch;
    }

    // 3. Install. /usr/sbin/installer needs root. If we're not, re-exec
    // ourselves under sudo with --install-dext (the cached .pkg gets
    // re-validated by the elevated invocation, so the only change vs.
    // running `installer` directly is that the user sees one sudo
    // password prompt instead of being told to run a separate command).
    if (c.geteuid() != 0) {
        const self_path = try std.process.executablePathAlloc(io, allocator);
        defer allocator.free(self_path);
        std.debug.print("Installing Karabiner-DriverKit-VirtualHIDDevice {s} (sudo will prompt for your password)...\n", .{pinned_dext_version});
        try runInherit(allocator, io, &.{ "/usr/bin/sudo", self_path, "--install-dext" }, error.SudoFailed);
        return;
    }

    try runInherit(allocator, io, &.{ "/usr/sbin/installer", "-pkg", pkg_path, "-target", "/" }, error.InstallerFailed);

    // 4. Register the VHIDD daemon with launchd. The pqrs .pkg's
    //    postinstall is a no-op `killall` — the launchd plist that
    //    historically registered the daemon ships with Karabiner-Elements,
    //    not the standalone DriverKit pkg, so without our help the daemon
    //    never gets a launchd entry on a fresh box.
    try installVhiddDaemon(allocator, io);

    std.debug.print(
        \\
        \\Karabiner-DriverKit-VirtualHIDDevice {s} installed. macOS may
        \\prompt to approve the system extension in System Settings →
        \\Privacy & Security; approve it before running skhd-grabber.
        \\
    , .{pinned_dext_version});
}

/// Spawn `argv` with stdio inherited (sudo / curl / installer prompts and
/// progress bars must reach the user's terminal). Returns `err_tag` on
/// non-zero exit or spawn failure. Used for interactive sub-commands the
/// caller wants to surface output for.
fn runInherit(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    err_tag: anyerror,
) !void {
    _ = allocator;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return err_tag;
    const term = child.wait(io) catch return err_tag;
    switch (term) {
        .exited => |code| if (code != 0) return err_tag,
        else => return err_tag,
    }
}

/// Install + bootstrap the VHIDD daemon's launchd entry. Coexists with
/// Karabiner-Elements: KE registers the same launchd label
/// (`org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon`) via
/// `SMAppService.daemon(plistName:)` from inside its app bundle, NOT via
/// `/Library/LaunchDaemons/`. Two registrations under the same label
/// would conflict, so we check whether launchd already has it (regardless
/// of source) and either:
///   - existing registration → skip plist write + bootstrap, just kickstart
///   - no registration → write our plist to /Library/LaunchDaemons/,
///     bootstrap, kickstart
///
/// Side effect on uninstall: we deliberately do NOT remove our VHIDD plist
/// in `uninstallGrabber` — leaving it behind keeps the daemon working for
/// any other consumer (e.g. user installs Karabiner-Elements after us).
fn installVhiddDaemon(allocator: std.mem.Allocator, io: std.Io) !void {
    const target = "system/" ++ vhidd_launchd_label;

    if (try launchdServiceRegistered(allocator, io, target)) {
        std.debug.print(
            \\VHIDD launchd entry already registered (Karabiner-Elements or a
            \\prior --install-dext run). Skipping plist install to avoid a
            \\duplicate registration; will just (re)kick the daemon.
            \\
        , .{});
        runLaunchctl(allocator, io, &.{ "kickstart", "-k", target }) catch {};
        std.Io.sleep(io, .fromMilliseconds(400), .awake) catch {};
        return;
    }

    if (!fileExists(io, vhidd_plist_path)) {
        std.debug.print("Installing VHIDD launchd plist → {s}\n", .{vhidd_plist_path});
        try writePlistAbsolute(io, vhidd_plist_path, vhidd_plist_template);
    }

    try bootstrapService(allocator, io, target, vhidd_plist_path);

    // Pause so checkHidDaemonState() right after this reports running
    // instead of the in-flight bootstrapped-but-not-yet-spawned state.
    std.Io.sleep(io, .fromMilliseconds(400), .awake) catch {};
}

/// Print the one-line `--status` summary for the HID daemon. Returns the
/// detected state so the caller can decide whether to print the
/// remediation block below the existing remediation chain. Errors during
/// the probe are reported inline and treated as `.running` so we don't
/// spam an irrelevant remediation in unusual environments.
pub fn printHidDaemonStatus(allocator: std.mem.Allocator, io: std.Io) HidDaemonState {
    const state = checkHidDaemonState(allocator, io) catch |err| {
        std.debug.print("  HID daemon:           Unknown ({s})\n", .{@errorName(err)});
        return .running;
    };

    const version = readHidDaemonVersion(allocator, io);
    defer if (version) |v| allocator.free(v);

    switch (state) {
        .running => {
            if (version) |v| {
                const compat = compareVersions(v, pinned_dext_version);
                const tag = switch (compat) {
                    .ok => "✓",
                    .older => "INCOMPATIBLE — older major",
                    .newer => "untested — newer major",
                    .parse_error => "version parse failed",
                };
                std.debug.print("  HID daemon:           Running (Karabiner DriverKit v{s}, pinned v{s} {s})\n", .{ v, pinned_dext_version, tag });
            } else {
                std.debug.print("  HID daemon:           Running (version unknown, pinned v{s})\n", .{pinned_dext_version});
            }
        },
        .not_installed => std.debug.print("  HID daemon:           Not installed (required for .remap / .taphold rules; pinned v{s})\n", .{pinned_dext_version}),
        .dext_disabled => {
            const v_str = version orelse "?";
            std.debug.print("  HID daemon:           DEXT v{s} loaded but DISABLED in System Settings (re-enable in Login Items & Extensions → Driver Extensions)\n", .{v_str});
        },
        .plist_unregistered => {
            const v_str = version orelse "?";
            std.debug.print("  HID daemon:           DEXT v{s} loaded but launchd entry missing\n", .{v_str});
        },
        .stopped => {
            const v_str = version orelse "?";
            std.debug.print("  HID daemon:           Stopped (Karabiner DriverKit v{s} installed)\n", .{v_str});
        },
    }

    if (isKarabinerElementsActive(allocator, io)) {
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
        .running => {}, // version-mismatch case handled by printVersionMismatchRemediation
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
        .dext_disabled => std.debug.print(
            \\
            \\Karabiner-DriverKit-VirtualHIDDevice is loaded but currently
            \\DISABLED in System Settings. The dext process keeps running so
            \\pgrep finds it, but the kernel won't dispatch HID requests
            \\through it — seize fails and vhidd injection silently no-ops.
            \\
            \\Re-enable: System Settings → General → Login Items & Extensions
            \\→ Driver Extensions → toggle Karabiner-VirtualHIDDevice
            \\Manager Extensions on.
            \\
            \\(SIP gates `systemextensionsctl activate` from the command line
            \\so this can only be done via the System Settings UI.)
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

/// Print remediation when the HID daemon is running but its major version
/// doesn't match the pinned one. Only worth surfacing for `.older` (IPC
/// likely broken); `.newer` is just an "untested" advisory, not blocking.
pub fn printVersionMismatchRemediation(installed: []const u8, compat: Compatibility) void {
    switch (compat) {
        .ok, .parse_error => {},
        .older => std.debug.print(
            \\
            \\HID daemon is running v{s}, older than the pinned major v{s}.
            \\skhd-grabber's IPC is validated against the pinned version; this
            \\older install may not match the wire format. Likely cause: an
            \\older Karabiner-Elements bundled an earlier DriverKit. Resolve
            \\by either upgrading Karabiner-Elements OR by installing our
            \\pinned version (which will replace the installed one):
            \\  zig build install-dext     # downloads + installs v{s}
            \\
        , .{ installed, pinned_dext_version, pinned_dext_version }),
        .newer => std.debug.print(
            \\
            \\HID daemon is running v{s}, newer than the pinned major v{s}.
            \\skhd-grabber hasn't been validated against this version. If
            \\.remap / .taphold rules misbehave, downgrade to the pinned
            \\version with:
            \\  zig build install-dext     # installs v{s}
            \\
        , .{ installed, pinned_dext_version, pinned_dext_version }),
    }
}

/// Send a hard-coded sample rule to the grabber so we can validate the
/// IPC plumbing end-to-end before parser integration lands. Logs at
/// the grabber side print the parsed rule.
pub fn grabberTestRule(allocator: std.mem.Allocator, io: std.Io, socket_path: []const u8) !void {
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

    var client = try Client.connect(allocator, io, socket_path);
    defer client.close();

    try client.hello();
    try client.applyRules(&sample_rules, &.{}, false);
    try client.bye();

    std.debug.print(
        "sent test rule (caps_lock → tap escape / hold lctrl) to {s}\n",
        .{socket_path},
    );
}
