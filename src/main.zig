const std = @import("std");
const builtin = @import("builtin");
const track_alloc = @import("build_options").track_alloc;

const c = @import("c.zig");
const DeviceCheck = @import("DeviceCheck.zig");
const grabber_cli = @import("grabber_cli.zig");
const grabber_protocol = @import("grabber_protocol");
const Mappings = @import("Mappings.zig");
const Parser = @import("Parser.zig");
const service = @import("service.zig");
const Skhd = @import("skhd.zig");
const synthesize = @import("synthesize.zig");
const TrackingAllocator = @import("TrackingAllocator.zig");

const version = std.mem.trimRight(u8, @embedFile("VERSION"), "\n\r\t ");
const log = std.log.scoped(.main);

/// Build-mode-aware log level: full debug locally, info in safe
/// release builds (so production daemons keep their session-start
/// marker, watchdog notices, etc.), warn-only in fast/small release
/// builds where the noise floor matters and we don't want info
/// chatter in user terminals. Mirrors the policy used by skhd-grabber.
pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe => .info,
        .ReleaseFast, .ReleaseSmall => .warn,
    },
};

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    // Get base allocator
    const base_gpa, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    };
    defer if (is_debug) {
        switch (debug_allocator.deinit()) {
            .ok => {},
            .leak => std.debug.print("memory leak detected\n", .{}),
        }
    };

    // Set up tracking allocator if enabled at compile time
    var tracker: if (track_alloc) TrackingAllocator else void = undefined;
    const gpa = if (comptime track_alloc) blk: {
        tracker = try TrackingAllocator.init(base_gpa);

        std.debug.print("=== Allocation Logging Enabled ===\n", .{});
        std.debug.print("All allocations and deallocations will be logged.\n\n", .{});

        break :blk tracker.allocator();
    } else base_gpa;

    defer if (comptime track_alloc) {
        std.debug.print("\n=== Final Allocation Report ===\n", .{});
        tracker.printReport(std.io.getStdErr().writer()) catch {};
        tracker.deinit();
    };

    // Parse command line arguments
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var config_file: ?[]const u8 = null;
    var verbose = false;
    var observe_mode = false;
    var no_hotload = false;
    var profile = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-c") or std.mem.eql(u8, args[i], "--config")) {
            if (i + 1 < args.len) {
                i += 1;
                config_file = args[i];
            } else {
                std.debug.print("Error: --config requires a file path\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, args[i], "-V") or std.mem.eql(u8, args[i], "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, args[i], "-o") or std.mem.eql(u8, args[i], "--observe")) {
            observe_mode = true;
        } else if (std.mem.eql(u8, args[i], "-v") or std.mem.eql(u8, args[i], "--version")) {
            std.debug.print("skhd.zig v{s}\n", .{version});
            return;
        } else if (std.mem.eql(u8, args[i], "-k") or std.mem.eql(u8, args[i], "--key")) {
            if (i + 1 < args.len) {
                i += 1;
                try synthesize.synthesizeKey(gpa, args[i]);
                return;
            } else {
                std.debug.print("Error: --key requires a key string\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, args[i], "-t") or std.mem.eql(u8, args[i], "--text")) {
            if (i + 1 < args.len) {
                i += 1;
                try synthesize.synthesizeText(gpa, args[i]);
                return;
            } else {
                std.debug.print("Error: --text requires a text string\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, args[i], "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, args[i], "--install-service")) {
            try service.installService(gpa);
            try maybeInstallGrabber(gpa);
            return;
        } else if (std.mem.eql(u8, args[i], "--uninstall-service")) {
            try service.uninstallService(gpa);
            return;
        } else if (std.mem.eql(u8, args[i], "--start-service")) {
            try service.startService(gpa);
            return;
        } else if (std.mem.eql(u8, args[i], "--stop-service")) {
            try service.stopService(gpa);
            return;
        } else if (std.mem.eql(u8, args[i], "--restart-service")) {
            try service.restartService(gpa);
            return;
        } else if (std.mem.eql(u8, args[i], "--status")) {
            try service.checkServiceStatus(gpa);
            return;
        } else if (std.mem.eql(u8, args[i], "-r") or std.mem.eql(u8, args[i], "--reload")) {
            try service.reloadConfig(gpa);
            return;
        } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--no-hotload")) {
            no_hotload = true;
        } else if (std.mem.eql(u8, args[i], "-P") or std.mem.eql(u8, args[i], "--profile")) {
            profile = true;
        } else if (std.mem.eql(u8, args[i], "--install-grabber")) {
            grabber_cli.installGrabber(gpa) catch std.process.exit(1);
            return;
        } else if (std.mem.eql(u8, args[i], "--install-dext")) {
            grabber_cli.installDext(gpa) catch std.process.exit(1);
            return;
        } else if (std.mem.eql(u8, args[i], "--uninstall-grabber")) {
            grabber_cli.uninstallGrabber(gpa) catch std.process.exit(1);
            return;
        } else if (std.mem.eql(u8, args[i], "--grabber-status")) {
            const path = consumeOptionalPath(args, &i) orelse grabber_protocol.default_socket_path;
            grabber_cli.grabberStatus(gpa, path) catch std.process.exit(1);
            return;
        } else if (std.mem.eql(u8, args[i], "--grabber-test-rule")) {
            const path = consumeOptionalPath(args, &i) orelse grabber_protocol.default_socket_path;
            grabber_cli.grabberTestRule(gpa, path) catch std.process.exit(1);
            return;
        }
    }

    if (observe_mode) {
        const echo = @import("echo.zig").echo;
        try echo();
        return;
    }

    // Resolve config file path
    const resolved_config_file = if (config_file) |cf|
        try gpa.dupe(u8, cf)
    else
        try getConfigFile(gpa, "skhdrc");
    defer gpa.free(resolved_config_file);

    // Check if another instance is already running
    if (!verbose) { // Only check in service mode
        if (try service.readPidFile(gpa)) |pid| {
            if (service.isProcessRunning(pid)) {
                std.debug.print("skhd is already running (PID {d})\n", .{pid});
                return;
            } else {
                // Clean up stale PID file
                service.removePidFile(gpa);
            }
        }
    }

    // Write PID file
    try service.writePidFile(gpa);
    defer service.removePidFile(gpa);

    // Capture stderr to ~/Library/Logs/skhd.log when launched as a daemon
    // (SMAppService wires stderr to /dev/null). Skipped for `-V` so verbose
    // runs always print to the invoking terminal/pipe, even if launchd
    // somehow set XPC_SERVICE_NAME.
    redirectDaemonStderr(gpa, verbose);
    logSessionStart();

    inheritUserPath(gpa);

    // Initialize and run skhd
    var skhd = try Skhd.init(gpa, resolved_config_file, verbose, profile);
    defer skhd.deinit();

    applyConfigPaths(gpa, skhd.mappings.paths.items);

    if (verbose) {
        log.info("Using config file: {s}", .{resolved_config_file});
        if (no_hotload) {
            log.info("Hot reload disabled", .{});
        } else {
            log.info("Hot reload enabled", .{});
        }
        if (profile) {
            log.info("Profiling enabled", .{});
        }
    }

    // Pass the hotload flag to run
    skhd.run(!no_hotload) catch {};
}

/// Consume the next CLI arg as an optional value if it doesn't look
/// like a new flag. Returns null and leaves the index alone otherwise.
/// Used by --grabber-status / --grabber-test-rule which take an
/// optional `<socket-path>` after the flag.
fn consumeOptionalPath(args: []const [:0]u8, i: *usize) ?[]const u8 {
    if (i.* + 1 >= args.len) return null;
    const next = args[i.* + 1];
    if (next.len > 0 and next[0] == '-') return null;
    i.* += 1;
    return next;
}

/// True iff this process was spawned by launchd as an XPC service /
/// LaunchAgent. The XPC framework sets `XPC_SERVICE_NAME` to the placeholder
/// "0" for normal user-shell processes (so it's almost always *set* — the
/// classic null-check is too loose); launchd overrides it with the real
/// service label (e.g. `com.jackielii.skhd`) only for actual services.
pub fn isLaunchdManaged() bool {
    const name = std.posix.getenv("XPC_SERVICE_NAME") orelse return false;
    return !std.mem.eql(u8, name, "0");
}

/// Redirect stderr to ~/Library/Logs/skhd.log when running under
/// SMAppService — the LaunchAgent.plist doesn't set StandardErrorPath, so
/// the daemon's stderr is /dev/null and every log.err / log.info is
/// silently dropped. Foreground runs (terminal or `zig build` subprocess)
/// keep stderr untouched so logs reach the user's terminal. `-V` always
/// forces no-redirect — verbose mode is for humans watching the output
/// live, never for log-file capture.
///
/// Detection signal: `XPC_SERVICE_NAME` is injected by launchd into every
/// service it spawns. It's absent for direct CLI invocations and for
/// processes started through `zig build`'s subprocess pipe — so it's a
/// stricter "am I really a daemon" test than isatty(2), which gets fooled
/// by the build system's stderr pipe.
fn redirectDaemonStderr(allocator: std.mem.Allocator, verbose: bool) void {
    if (verbose) return;
    if (!isLaunchdManaged()) return;

    const home = std.posix.getenv("HOME") orelse return;
    const path = std.fmt.allocPrintZ(allocator, "{s}/Library/Logs/skhd.log", .{home}) catch return;
    defer allocator.free(path);

    const fd = c.open(path.ptr, c.O_WRONLY | c.O_CREAT | c.O_APPEND, @as(c_int, 0o644));
    if (fd < 0) return;
    defer _ = c.close(fd);

    _ = c.dup2(fd, 2);
}

/// Mark the start of a new session in the log so it's easy to find where the
/// current run begins after a respawn. Single line, ISO-8601 UTC timestamp,
/// version, and PID.
fn logSessionStart() void {
    const ts = std.time.timestamp();
    if (ts < 0) return;

    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_secs.getDaySeconds();

    log.warn("=== skhd {s} started at {d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z (PID {d}) ===", .{
        version,
        @as(u32, year_day.year),
        @intFromEnum(month_day.month),
        @as(u32, month_day.day_index) + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
        @as(i32, @intCast(std.c.getpid())),
    });
}

/// Resolve the user's login shell. Prefers `SHELL` env (the shell the user is
/// actively using — terminal apps may override pw_shell), then falls back to
/// `getpwuid(getuid()).pw_shell` from Open Directory. The pw_shell fallback is
/// what fixes #36: under SMAppService, SHELL can be unset, so the previous
/// implementation silently bailed out. pw_shell is the same source `login(1)`
/// uses and is reliable under launchd.
fn detectLoginShell(allocator: std.mem.Allocator) ?[:0]const u8 {
    if (std.posix.getenv("SHELL")) |shell| {
        if (shell.len > 0) return allocator.dupeZ(u8, shell) catch null;
    }
    if (c.getpwuid(c.getuid())) |pw| {
        if (pw.*.pw_shell) |shell_ptr| {
            const slice = std.mem.sliceTo(shell_ptr, 0);
            if (slice.len > 0) return allocator.dupeZ(u8, slice) catch null;
        }
    }
    return null;
}

/// Capture PATH using a shell-specific invocation. `-i` is dropped on every
/// shell because interactive init under launchd's no-tty environment is the
/// main source of failures: zsh's `compinit` writes warnings to stdout, fish
/// prompts that probe terminal capabilities can hang, and rc files commonly
/// assume `read`/colorized output works. PATH belongs in profile/login files
/// anyway, which `-l` (or fish's always-sourced `config.fish`) covers.
///
/// Returns the trimmed colon-joined PATH on success, null on any failure
/// (with the failure logged at warn level so it survives in the daemon log).
fn capturePath(allocator: std.mem.Allocator, shell_path: []const u8) ?[]u8 {
    const shell_name = std.fs.path.basename(shell_path);

    // fish stores PATH as a list and `printenv PATH` prints it
    // space-separated. `string join : $PATH` gives the colon-joined form
    // every other tool expects. fish always sources `config.fish` and
    // `conf.d/*.fish`, so no `-l` flag is needed.
    const argv: []const []const u8 = if (std.mem.eql(u8, shell_name, "fish"))
        &.{ shell_path, "-c", "string join : $PATH" }
    else
        &.{ shell_path, "-lc", "printenv PATH" };

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch |err| {
        log.warn("PATH capture: spawn {s} failed: {s}", .{ shell_path, @errorName(err) });
        return null;
    };

    var stdout_data = std.ArrayList(u8).init(allocator);
    defer stdout_data.deinit();
    if (child.stdout) |stdout| {
        stdout.reader().readAllArrayList(&stdout_data, 64 * 1024) catch |err| {
            _ = child.wait() catch {};
            log.warn("PATH capture: read stdout failed: {s}", .{@errorName(err)});
            return null;
        };
    }
    const term = child.wait() catch |err| {
        log.warn("PATH capture: wait failed: {s}", .{@errorName(err)});
        return null;
    };
    if (term != .Exited or term.Exited != 0) {
        log.warn("PATH capture: {s} exited abnormally: {any}", .{ shell_path, term });
        return null;
    }

    const trimmed = std.mem.trim(u8, stdout_data.items, " \r\n\t");
    if (trimmed.len == 0) {
        log.warn("PATH capture: {s} returned empty PATH", .{shell_path});
        return null;
    }

    return allocator.dupe(u8, trimmed) catch null;
}

/// Augment PATH from the user's login shell so commands launched by hotkeys
/// resolve the same as they do in a terminal. launchd starts services with a
/// minimal `PATH=/usr/bin:/bin:/usr/sbin:/sbin` that excludes Homebrew
/// (`/opt/homebrew/bin`, `/usr/local/bin`), `~/.local/bin`, and similar — so
/// commands like `yabai` or `jq` referenced bare in skhdrc fail to exec.
/// This is the same problem (and same fix) GUI editors like VS Code solve.
fn inheritUserPath(allocator: std.mem.Allocator) void {
    const shell = detectLoginShell(allocator) orelse {
        log.warn("PATH inheritance: no login shell (SHELL unset and getpwuid failed)", .{});
        return;
    };
    defer allocator.free(shell);

    const captured = capturePath(allocator, shell) orelse return;
    defer allocator.free(captured);

    const path_z = allocator.dupeZ(u8, captured) catch return;
    defer allocator.free(path_z);

    if (c.setenv("PATH", path_z.ptr, 1) != 0) {
        log.warn("PATH inheritance: setenv failed", .{});
        return;
    }
    log.warn("PATH inherited from {s}: {s}", .{ shell, captured });
}

/// Prepend `.path` directive entries to PATH. Called after inheritUserPath so
/// the layering is:
///   `<.path entries, in declaration order> : <inherited PATH>`
/// Explicit user entries take precedence over what shell inheritance found,
/// which matters for tool-version-managers (mise/asdf shims) where the user
/// wants the shim dir resolved before any system tool of the same name.
fn applyConfigPaths(allocator: std.mem.Allocator, entries: []const []const u8) void {
    if (entries.len == 0) return;

    const current = std.posix.getenv("PATH") orelse "";

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    for (entries) |entry| {
        buf.appendSlice(entry) catch return;
        buf.append(':') catch return;
    }
    buf.appendSlice(current) catch return;
    buf.append(0) catch return;

    if (c.setenv("PATH", @ptrCast(buf.items.ptr), 1) != 0) {
        log.warn("PATH apply: setenv failed", .{});
        return;
    }
    log.warn("PATH after .path directives: {s}", .{buf.items[0 .. buf.items.len - 1]});
}

/// Resolve config file path following XDG spec
/// Tries in order:
/// 1. $XDG_CONFIG_HOME/skhd/<filename>
/// 2. $HOME/.config/skhd/<filename>
/// 3. $HOME/.<filename>
pub fn getConfigFile(allocator: std.mem.Allocator, filename: []const u8) ![]const u8 {
    // Try XDG_CONFIG_HOME first
    if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg_home| {
        const path = try std.fmt.allocPrint(allocator, "{s}/skhd/{s}", .{ xdg_home, filename });
        defer allocator.free(path);

        if (fileExists(path)) {
            return try allocator.dupe(u8, path);
        }
    }

    // Try HOME/.config/skhd
    if (std.posix.getenv("HOME")) |home| {
        const config_path = try std.fmt.allocPrint(allocator, "{s}/.config/skhd/{s}", .{ home, filename });
        defer allocator.free(config_path);

        if (fileExists(config_path)) {
            return try allocator.dupe(u8, config_path);
        }

        // Try HOME/.skhdrc (dotfile in home)
        const dotfile_path = try std.fmt.allocPrint(allocator, "{s}/.{s}", .{ home, filename });
        defer allocator.free(dotfile_path);

        if (fileExists(dotfile_path)) {
            return try allocator.dupe(u8, dotfile_path);
        }
    }

    // Default to filename in current directory
    return try allocator.dupe(u8, filename);
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Run after a successful `--install-service`. Checks whether the
/// user's config has any caps_lock-class `.remap` block-form rules
/// targeting a currently-connected device — those need the system
/// grabber. If so and the grabber isn't already installed, prints
/// the situation and offers to install it now via sudo. The user
/// always has the choice to decline and run `sudo skhd
/// --install-grabber` themselves.
///
/// Skips silently on Mac Studio / external-keyboard-only setups
/// where no caps-class rule's target device is connected — the
/// agent's runtime path (DeviceCheck in forwardTapholdsToGrabber)
/// also handles this, so installing the grabber there would just be
/// dead weight.
fn maybeInstallGrabber(allocator: std.mem.Allocator) !void {
    if (grabber_cli.isGrabberInstalled()) {
        std.debug.print("\nskhd-grabber is already installed.\n", .{});
        return;
    }

    // Parse the user's config to find caps-class rules.
    const config_path = getConfigFile(allocator, "skhdrc") catch |err| {
        std.debug.print("\n(could not resolve config file: {s})\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(config_path);

    var mappings = Mappings.init(allocator) catch return;
    defer mappings.deinit();

    var parser = Parser.init(allocator) catch return;
    defer parser.deinit();

    const content = std.fs.cwd().readFileAlloc(allocator, config_path, 1 << 20) catch |err| {
        std.debug.print("\n(could not read config {s}: {s} — skipping grabber check)\n", .{ config_path, @errorName(err) });
        return;
    };
    defer allocator.free(content);

    parser.parseWithPath(&mappings, content, config_path) catch return;
    parser.processLoadDirectives(&mappings) catch return;

    if (mappings.tapholds.items.len == 0) {
        std.debug.print("\nNo caps_lock-class rules in config — skhd-grabber not needed.\n", .{});
        return;
    }

    // Filter by device presence so a config shared between a laptop
    // and a Mac Studio doesn't force grabber install on the Studio.
    var any_present = false;
    var first_alias: ?[]const u8 = null;
    for (mappings.tapholds.items) |th| {
        const alias = mappings.device_aliases.get(th.device_alias) orelse continue;
        if (DeviceCheck.isPresent(alias.vendor, alias.product)) {
            any_present = true;
            if (first_alias == null) first_alias = th.device_alias;
            break;
        }
    }
    if (!any_present) {
        std.debug.print("\nConfig has caps_lock-class rules, but none of the targeted devices are connected — skhd-grabber not needed on this machine.\n", .{});
        return;
    }

    std.debug.print(
        \\
        \\Config has caps_lock-class rules for connected device '{s}'.
        \\skhd-grabber is required to handle them — it runs as a system
        \\daemon (root) and seizes the keyboard for tap-hold processing.
        \\
        \\Install it now? (you'll be prompted for your sudo password) [Y/n]
    , .{first_alias.?});

    const answer = readLine(allocator) catch {
        std.debug.print("\n(could not read answer; run `sudo skhd --install-grabber` to install manually)\n", .{});
        return;
    };
    defer allocator.free(answer);
    const trimmed = std.mem.trim(u8, answer, " \t\r");
    if (trimmed.len > 0 and (trimmed[0] == 'n' or trimmed[0] == 'N')) {
        std.debug.print(
            \\Skipping. To install later:
            \\  sudo skhd --install-grabber
            \\
        , .{});
        return;
    }

    grabber_cli.installGrabberViaSudo(allocator) catch |err| {
        std.debug.print(
            \\
            \\Grabber install via sudo failed ({s}). Try running it directly:
            \\  sudo skhd --install-grabber
            \\
        , .{@errorName(err)});
        return;
    };
    std.debug.print("\nskhd-grabber installed.\n", .{});
}

/// Read one line from stdin (up to newline). Returns owned slice
/// including any trailing carriage return; caller is responsible for
/// trimming.
fn readLine(allocator: std.mem.Allocator) ![]u8 {
    const stdin = std.io.getStdIn().reader();
    return try stdin.readUntilDelimiterAlloc(allocator, '\n', 64);
}

fn printHelp() void {
    std.debug.print(
        \\skhd - Simple Hotkey Daemon for macOS
        \\
        \\Usage: skhd [options]
        \\
        \\Options:
        \\  -c, --config <file>    Specify config file (default: skhdrc)
        \\  -V, --verbose          Enable verbose output (interactive mode)
        \\  -P, --profile          Enable profiling/tracing mode
        \\  -o, --observe          Observe mode - print key events
        \\  -h, --no-hotload       Disable system for hotloading config file
        \\  -k, --key <keyspec>    Synthesize a keypress
        \\  -t, --text <text>      Synthesize text input
        \\  -r, --reload           Reload config on running instance
        \\  -v, --version          Print version
        \\      --help             Show this help message
        \\
        \\Service Management:
        \\      --install-service   Register the bundled LaunchAgent with macOS
        \\                          via SMAppService (BTM-tracked, auto-starts
        \\                          at login)
        \\      --uninstall-service Unregister and remove
        \\      --start-service     Start the service
        \\      --stop-service      Stop the service (transient — relaunches
        \\                          on next login)
        \\      --restart-service   Restart the service
        \\      --status            Check service status
        \\
        \\System Grabber (caps_lock-class tap-hold, opt-in):
        \\      --install-grabber       Install skhd-grabber LaunchDaemon (sudo)
        \\      --uninstall-grabber     Remove skhd-grabber LaunchDaemon (sudo)
        \\      --grabber-status [path] Ping the grabber's IPC socket
        \\      --grabber-test-rule [path]
        \\                              Send a sample tap-hold rule to the grabber
        \\                              for IPC plumbing verification
        \\
    , .{});
}
