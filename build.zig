const std = @import("std");

// macOS SDK path resolved once via xcrun and reused for every artifact's
// framework / include / library search paths.
var sdk_path: ?[]const u8 = null;

fn addSdkPaths(b: *std.Build, mod: *std.Build.Module) void {
    // Explicit os_version_min flips Zig out of "native" mode, so it stops
    // auto-adding the macOS SDK to the framework search path. Re-add it
    // from the SDK path stashed by build().
    //
    // Zig 0.16 dropped the Apple subframework auto-discovery that translate-c
    // used to rely on, so umbrella headers like `<Carbon/Carbon.h>` no longer
    // expand. `c.zig` is pinned to specific subframework headers, but those
    // subframeworks (HIToolbox, HIServices, FSEvents, ATS, …) are nested
    // under their parent framework's `Frameworks/` directory and need
    // additional `-iframework`/`-F` paths to resolve.
    if (sdk_path) |sdk| {
        const fw = b.fmt("{s}/System/Library/Frameworks", .{sdk});
        mod.addSystemFrameworkPath(.{ .cwd_relative = fw });
        mod.addFrameworkPath(.{ .cwd_relative = fw });
        mod.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sdk}) });
        mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });

        const sub_framework_dirs = [_][]const u8{
            "System/Library/Frameworks/CoreServices.framework/Frameworks",
            "System/Library/Frameworks/ApplicationServices.framework/Frameworks",
            "System/Library/Frameworks/Carbon.framework/Frameworks",
        };
        for (sub_framework_dirs) |rel| {
            const path = b.fmt("{s}/{s}", .{ sdk, rel });
            mod.addSystemFrameworkPath(.{ .cwd_relative = path });
            mod.addFrameworkPath(.{ .cwd_relative = path });
        }
    }
}

fn linkAgentFrameworks(b: *std.Build, mod: *std.Build.Module) void {
    addSdkPaths(b, mod);
    mod.linkFramework("Cocoa", .{});
    mod.linkFramework("Carbon", .{});
    mod.linkFramework("CoreServices", .{});
    // ServiceManagement: SMAppService.agent / register / unregister, used
    // by --register-service to register the bundled LaunchAgent with BTM.
    mod.linkFramework("ServiceManagement", .{});
    // IOKit: IOHIDManager enumeration in DeviceCheck.zig (decides
    // whether to dial the grabber based on connected devices).
    mod.linkFramework("IOKit", .{});
}

fn linkGrabberFrameworks(b: *std.Build, mod: *std.Build.Module) void {
    addSdkPaths(b, mod);
    mod.linkFramework("IOKit", .{});
    mod.linkFramework("CoreFoundation", .{});
    // CoreGraphics for CGEventSourceFlagsState — used to detect when
    // Apple firmware has toggled caps_lock against our intent so we
    // can flip it back via a vhidd-injected caps_lock toggle.
    mod.linkFramework("CoreGraphics", .{});
    // SystemConfiguration for SCDynamicStoreCopyConsoleUser — D5
    // tracks the active console user and only applies rules from
    // their agent. Multi-user / fast-user-switching support.
    mod.linkFramework("SystemConfiguration", .{});
}

fn addVersionImport(b: *std.Build, mod: *std.Build.Module) void {
    const mode_str = switch (mod.optimize.?) {
        .Debug => "debug",
        .ReleaseSafe => "safe",
        .ReleaseFast => "fast",
        .ReleaseSmall => "small",
    };

    const version_step = b.addSystemCommand(&[_][]const u8{
        "sh", "-c",
        b.fmt(
            \\VERSION=$(cat VERSION | tr -d '\n')
            \\GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')
            \\# Check if working tree is dirty
            \\if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
            \\    DIRTY="-dirty"
            \\else
            \\    DIRTY=""
            \\fi
            \\# Check if we're on a tagged commit
            \\if git describe --exact-match --tags HEAD >/dev/null 2>&1; then
            \\    # On a tag, just show version-hash
            \\    printf "%s-%s%s ({s})" "$VERSION" "$GIT_HASH" "$DIRTY"
            \\else
            \\    # Not on a tag, show version-dev-hash
            \\    printf "%s-dev-%s%s ({s})" "$VERSION" "$GIT_HASH" "$DIRTY"
            \\fi
        , .{ mode_str, mode_str }),
    });
    version_step.has_side_effects = true;

    const version_file = version_step.captureStdOut(.{});
    mod.addAnonymousImport("VERSION", .{
        .root_source_file = version_file,
    });
}

/// Register the embedded launchd plists used by `--install-grabber` and
/// `--install-dext`. Plists live outside `src/` so anonymous imports are
/// the right shape (Zig restricts `@embedFile` to within the module's
/// package). Call this on every binary that links grabber_cli (currently
/// skhd, skhd-alloc, and unit-test executables).
fn addGrabberPlistImports(b: *std.Build, mod: *std.Build.Module) void {
    mod.addAnonymousImport("grabber_plist", .{
        .root_source_file = b.path("scripts/com.jackielii.skhd.grabber.plist"),
    });
    mod.addAnonymousImport("vhidd_plist", .{
        .root_source_file = b.path("assets/karabiner-virtualhiddevice-daemon.plist"),
    });
}

const track_alloc_option = "track_alloc";

// Pinned Karabiner-DriverKit-VirtualHIDDevice version. skhd-grabber's IPC
// is validated against this exact version of the dext + userland daemon.
// Same-major versions are assumed wire-compatible (pqrs project follows
// SemVer); different major triggers a runtime warning. Bump procedure:
//   1. Update _version to the new tag.
//   2. Update _url accordingly.
//   3. `curl -fsSL <url> | shasum -a 256` and paste into _sha256.
//   4. Test `zig build install-dext` end-to-end on a clean machine.
const karabiner_dext_version = "6.14.0";
const karabiner_dext_url = "https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases/download/v" ++ karabiner_dext_version ++ "/Karabiner-DriverKit-VirtualHIDDevice-" ++ karabiner_dext_version ++ ".pkg";
const karabiner_dext_sha256 = "ebfb6a643ea98bb7c2e08a4f99353b2a3129e397f4302340443bbd936f12eb1c";

fn addBuildOptions(b: *std.Build, track_alloc: bool) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(bool, track_alloc_option, track_alloc);
    options.addOption([]const u8, "karabiner_dext_version", karabiner_dext_version);
    options.addOption([]const u8, "karabiner_dext_url", karabiner_dext_url);
    options.addOption([]const u8, "karabiner_dext_sha256", karabiner_dext_sha256);
    return options;
}

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Pin macOS deployment target. Without this, Zig stamps the Mach-O's
    // LC_BUILD_VERSION minos with the build host's OS version, so binaries
    // built on macos-latest CI runners (now Tahoe 26) refuse to launch on
    // macOS 15.x with "You can't use this version of application 'skhd' with
    // this version of macOS." 13.0 matches the Info.plist's
    // LSMinimumSystemVersion and is the floor required by SMAppService.
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .os_tag = .macos,
            .os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } },
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    // Setting os_version_min above makes Zig treat the target as non-native
    // and stop auto-resolving the macOS SDK, so framework links fail. Probe
    // xcrun for the SDK and add its paths to every artifact via
    // linkAgentFrameworks/linkGrabberFrameworks. Setting b.sysroot would
    // double-prefix paths added with cwd_relative, so we stash the SDK path
    // in a module-level var instead.
    if (target.result.os.tag == .macos) {
        const out = b.run(&.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" });
        sdk_path = std.mem.trim(u8, out, " \n\r\t");
    }

    // Shared protocol module: types + framing for the agent ↔ grabber
    // IPC. Both binaries (and tests that exercise either side of the
    // protocol) addImport this so they agree on the wire format.
    const grabber_protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/grabber_protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Main executable
    const exe_options = addBuildOptions(b, false);
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkAgentFrameworks(b, exe_mod);
    addVersionImport(b, exe_mod);
    addGrabberPlistImports(b, exe_mod);
    exe_mod.addOptions("build_options", exe_options);
    exe_mod.addImport("grabber_protocol", grabber_protocol_mod);

    const exe = b.addExecutable(.{
        .name = "skhd",
        .root_module = exe_mod,
    });
    // Zig's MachO linker emits zero headerpad on x86_64 (arm64 gets an
    // ad-hoc LC_CODE_SIGNATURE already). codesign then silently
    // overwrites the first bytes of __TEXT,__text with its load
    // command, corrupting the first function and crashing signed
    // binaries on Intel with SIGILL/SIGBUS (#46, ziglang/zig#23704).
    exe.headerpad_size = 0x1000;
    b.installArtifact(exe);

    // skhd-grabber: system daemon (root) for caps_lock-class tap-hold.
    // Plain Mach-O — installed by `skhd --install-grabber` to
    // /usr/local/libexec/skhd-grabber and started by launchd. Needs
    // IOKit (D3 seize + run loop) and CoreFoundation (matching dicts).
    const grabber_mod = b.createModule(.{
        .root_source_file = b.path("src/grabber/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkGrabberFrameworks(b, grabber_mod);
    grabber_mod.addImport("grabber_protocol", grabber_protocol_mod);
    addVersionImport(b, grabber_mod);

    const grabber_exe = b.addExecutable(.{
        .name = "skhd-grabber",
        .root_module = grabber_mod,
    });
    // Same codesign headerpad fix as skhd above — the grabber is signed too.
    grabber_exe.headerpad_size = 0x1000;
    b.installArtifact(grabber_exe);

    // `zig build grabber-app` — build the grabber binary, wrap it in
    // skhd-grabber-dev.app, and code-sign with the local dev cert.
    //
    // Why a .app bundle? macOS Tahoe's TCC keys Input Monitoring (and
    // other HID-related) grants on bundle ID for .app bundles. A bare
    // Mach-O is keyed by cdhash + path, which gets invalidated every
    // rebuild and doesn't even render in System Settings → Input
    // Monitoring (so the user can't toggle approval). Wrapping the
    // grabber in a bundle gives it a stable ID, makes it visible in
    // the privacy panel, and survives `zig build` recompiles. Same
    // pattern skhd-dev.app uses for the agent.
    //
    // The actual binary inside the bundle is signed with skhd-dev-cert
    // and identifier com.jackielii.skhd.grabber.dev. Run as:
    //   sudo zig-out/skhd-grabber-dev.app/Contents/MacOS/skhd-grabber [args]
    const grabber_dev_cert = "skhd-dev-cert";
    const grabber_dev_bundle_id = "com.jackielii.skhd.grabber.dev";
    const installed_grabber_app = b.getInstallPath(.prefix, "skhd-grabber-dev.app");

    const grabber_app_cmd = b.addSystemCommand(&[_][]const u8{
        "bash",
        "scripts/make-grabber-app.sh",
    });
    grabber_app_cmd.addArg(b.getInstallPath(.bin, grabber_exe.name));
    grabber_app_cmd.addArg(installed_grabber_app);
    grabber_app_cmd.addArg(grabber_dev_bundle_id);
    grabber_app_cmd.step.dependOn(b.getInstallStep());

    const sign_grabber_app_cmd = b.addSystemCommand(&[_][]const u8{
        "bash",
        "scripts/codesign.sh",
    });
    sign_grabber_app_cmd.addArg(installed_grabber_app);
    sign_grabber_app_cmd.setEnvironmentVariable("SKHD_CERT", grabber_dev_cert);
    sign_grabber_app_cmd.setEnvironmentVariable("SKHD_BUNDLE_ID", grabber_dev_bundle_id);
    sign_grabber_app_cmd.step.dependOn(&grabber_app_cmd.step);

    const grabber_app_step = b.step("grabber-app", "Build skhd-grabber-dev.app (signed bundle for TCC-stable Input Monitoring grants)");
    grabber_app_step.dependOn(&sign_grabber_app_cmd.step);

    // `zig build run-grabber` — build + sign the bundle, then exec it
    // under sudo with --foreground. The bundle path is the entry point
    // because TCC keys Input Monitoring on it; running the bare binary
    // gets denied silently after the next rebuild invalidates its cdhash.
    // Extra args after `--` flow through (e.g. `zig build run-grabber --
    // --socket-path /tmp/x.sock`).
    const grabber_inner_exe = b.pathJoin(&.{ installed_grabber_app, "Contents", "MacOS", "skhd-grabber" });
    const run_grabber_cmd = b.addSystemCommand(&[_][]const u8{ "sudo", grabber_inner_exe, "--foreground" });
    run_grabber_cmd.step.dependOn(&sign_grabber_app_cmd.step);
    if (b.args) |args| run_grabber_cmd.addArgs(args);

    const run_grabber_step = b.step("run-grabber", "Build skhd-grabber-dev.app and run it under sudo --foreground");
    run_grabber_step.dependOn(&run_grabber_cmd.step);

    const installed_exe = b.getInstallPath(.bin, exe.name);
    const installed_app = b.getInstallPath(.prefix, "skhd.app");

    // .app bundle step. Wraps the binary into skhd.app so macOS Tahoe's
    // Accessibility picker accepts it and TCC keys entries by bundle ID
    // (com.jackielii.skhd) instead of by the binary's path. Inner binary at
    // skhd.app/Contents/MacOS/skhd is a copy, not a symlink, so codesigning
    // works. Scripts have bash shebangs and use bash-only `[[ ... ]]` syntax,
    // so invoke via bash explicitly (`/bin/sh` may not be bash on every
    // system that runs `zig build`).
    const app_cmd = b.addSystemCommand(&[_][]const u8{
        "bash",
        "scripts/make-app.sh",
    });
    app_cmd.addArg(installed_exe);
    app_cmd.addArg(installed_app);
    app_cmd.step.dependOn(b.getInstallStep());

    const app_step = b.step("app", "Build the skhd.app bundle wrapper");
    app_step.dependOn(&app_cmd.step);

    // Code signing.
    //   `zig build sign`     - signs the bare binary at zig-out/bin/skhd.
    //   `zig build sign-app` - signs the .app bundle (inner Mach-O + bundle
    //                          layer); use this after `zig build app` for
    //                          Tahoe-compatible installs.
    const sign_cmd = b.addSystemCommand(&[_][]const u8{
        "bash",
        "scripts/codesign.sh",
    });
    sign_cmd.addArg(installed_exe);
    sign_cmd.step.dependOn(b.getInstallStep());

    const sign_step = b.step("sign", "Code sign the bare binary");
    sign_step.dependOn(&sign_cmd.step);

    const sign_app_cmd = b.addSystemCommand(&[_][]const u8{
        "bash",
        "scripts/codesign.sh",
    });
    sign_app_cmd.addArg(installed_app);
    sign_app_cmd.step.dependOn(&app_cmd.step);

    const sign_app_step = b.step("sign-app", "Build and code sign the skhd.app bundle (Tahoe-compatible)");
    sign_app_step.dependOn(&sign_app_cmd.step);

    // Local debug bundle. Uses a separate path, cert (skhd-dev-cert), and
    // bundle ID (com.jackielii.skhd.dev) so debug runs get their own TCC slot
    // and don't disturb the prod entry (com.jackielii.skhd + skhd-cert) used
    // by the Homebrew install. On Tahoe, TCC is bundle-ID-keyed and validates
    // against the stored csreq, so the running process must carry the right
    // bundle ID and a signature matching the granted entry — the bare binary
    // at zig-out/bin/skhd is adhoc-signed and unbundled, so it can't be
    // granted accessibility on Tahoe.
    const installed_dev_app = b.getInstallPath(.prefix, "skhd-dev.app");
    const dev_bundle_id = "com.jackielii.skhd.dev";
    const dev_cert_name = "skhd-dev-cert";

    const dev_app_cmd = b.addSystemCommand(&[_][]const u8{
        "bash",
        "scripts/make-app.sh",
    });
    dev_app_cmd.addArg(installed_exe);
    dev_app_cmd.addArg(installed_dev_app);
    dev_app_cmd.addArg(dev_bundle_id);
    dev_app_cmd.step.dependOn(b.getInstallStep());

    const sign_dev_app_cmd = b.addSystemCommand(&[_][]const u8{
        "bash",
        "scripts/codesign.sh",
    });
    sign_dev_app_cmd.addArg(installed_dev_app);
    sign_dev_app_cmd.setEnvironmentVariable("SKHD_CERT", dev_cert_name);
    sign_dev_app_cmd.setEnvironmentVariable("SKHD_BUNDLE_ID", dev_bundle_id);
    sign_dev_app_cmd.step.dependOn(&dev_app_cmd.step);

    const inner_exe = b.pathJoin(&.{ installed_dev_app, "Contents", "MacOS", "skhd" });
    const run_cmd = b.addSystemCommand(&[_][]const u8{inner_exe});
    run_cmd.step.dependOn(&sign_dev_app_cmd.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // `zig build install-local` — stage the local build into the slot a
    // brew install would occupy: replace the binary inside
    // /Applications/skhd.app and re-sign with skhd-cert + prod bundle id.
    // Stops the SMAppService daemon during the swap but does not restart
    // it — run `skhd --start-service` when ready. Lets you exercise the
    // packaged path (real bundle id, real launchd registration, real TCC
    // slot) without cutting a release. Pass -Doptimize=ReleaseFast to
    // match the brew binary's perf profile.
    const install_local_cmd = b.addSystemCommand(&[_][]const u8{
        "bash",
        "scripts/install-local.sh",
    });
    install_local_cmd.addArg(installed_exe);
    install_local_cmd.step.dependOn(b.getInstallStep());

    const install_local_step = b.step("install-local", "Install the local build into /Applications/skhd.app (test the packaged path without releasing; does not start the service)");
    install_local_step.dependOn(&install_local_cmd.step);

    // `zig build install-dext` — download + install the pinned Karabiner
    // DriverKit .pkg by invoking the just-built skhd binary's
    // `--install-dext` subcommand. Same code path brew users hit, so dev
    // and prod stay in lockstep. Cached under ~/.cache/skhd so re-runs
    // skip the download; pqrs's installer is a no-op when the same
    // version is already installed.
    const install_dext_cmd = b.addSystemCommand(&[_][]const u8{installed_exe});
    install_dext_cmd.addArg("--install-dext");
    install_dext_cmd.has_side_effects = true;
    install_dext_cmd.step.dependOn(b.getInstallStep());

    const install_dext_step = b.step("install-dext", "Download and install pinned Karabiner-DriverKit-VirtualHIDDevice (required by skhd-grabber)");
    install_dext_step.dependOn(&install_dext_cmd.step);

    // `zig build check-c-constants` — cross-check c.zig's hand-rolled
    // integer constants against Apple's SDK headers. tools/check_c_constants.c
    // is a `_Static_assert` table; clang -fsyntax-only flags any mismatch
    // at compile time. Catches the class of bug where a hand-rolled hex
    // literal silently disagrees with the SDK (e.g. kEventAppFrontSwitched
    // was once 'fwsw' when it should be 7, see commit 9bd7b0d).
    const check_constants_cmd = b.addSystemCommand(&[_][]const u8{
        "clang",
        "-fsyntax-only",
        "-Wno-deprecated-declarations",
    });
    check_constants_cmd.addFileArg(b.path("tools/check_c_constants.c"));
    const check_constants_step = b.step(
        "check-c-constants",
        "Cross-check c.zig hand-rolled integer constants against Apple SDK headers",
    );
    check_constants_step.dependOn(&check_constants_cmd.step);

    // `zig build test` also runs check-c-constants — the comptime drift
    // test (in src/tests.zig) covers c.zig ↔ .c divergence, and clang
    // here covers .c ↔ SDK divergence; both must pass for tests to
    // succeed.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&check_constants_cmd.step);

    // Benchmark executable
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/benchmark.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    linkAgentFrameworks(b, bench_mod);
    addVersionImport(b, bench_mod);

    const zbench = b.dependency("zbench", .{
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("zbench", zbench.module("zbench"));

    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = bench_mod,
    });

    const bench_cmd = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);

    // Allocation tracking executable. Goes through the same dev .app + sign
    // path as `zig build run` so TCC's accessibility grant covers it — bare
    // Mach-O can't be granted on Tahoe. Same skhd-dev-cert + bundle id, so
    // there's only one TCC slot to manage; the .app's inner binary swaps
    // between the regular dev build and the alloc-tracking build depending
    // on which step you run last.
    const alloc_options = addBuildOptions(b, true);
    const alloc_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkAgentFrameworks(b, alloc_mod);
    addVersionImport(b, alloc_mod);
    addGrabberPlistImports(b, alloc_mod);
    alloc_mod.addOptions("build_options", alloc_options);
    alloc_mod.addImport("grabber_protocol", grabber_protocol_mod);

    const alloc_exe = b.addExecutable(.{
        .name = "skhd-alloc",
        .root_module = alloc_mod,
    });
    b.installArtifact(alloc_exe);
    const installed_alloc_exe = b.getInstallPath(.bin, alloc_exe.name);

    const alloc_app_cmd = b.addSystemCommand(&[_][]const u8{
        "bash",
        "scripts/make-app.sh",
    });
    alloc_app_cmd.addArg(installed_alloc_exe);
    alloc_app_cmd.addArg(installed_dev_app);
    alloc_app_cmd.addArg(dev_bundle_id);
    alloc_app_cmd.step.dependOn(b.getInstallStep());

    const sign_alloc_app_cmd = b.addSystemCommand(&[_][]const u8{
        "bash",
        "scripts/codesign.sh",
    });
    sign_alloc_app_cmd.addArg(installed_dev_app);
    sign_alloc_app_cmd.setEnvironmentVariable("SKHD_CERT", dev_cert_name);
    sign_alloc_app_cmd.setEnvironmentVariable("SKHD_BUNDLE_ID", dev_bundle_id);
    sign_alloc_app_cmd.step.dependOn(&alloc_app_cmd.step);

    const alloc_cmd = b.addSystemCommand(&[_][]const u8{inner_exe});
    alloc_cmd.step.dependOn(&sign_alloc_app_cmd.step);
    if (b.args) |args| {
        alloc_cmd.addArgs(args);
    }
    const alloc_step = b.step("alloc", "Run skhd with allocation logging (signed dev .app)");
    alloc_step.dependOn(&alloc_cmd.step);

    // Unit tests for main.zig
    const exe_test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkAgentFrameworks(b, exe_test_mod);
    addVersionImport(b, exe_test_mod);
    addGrabberPlistImports(b, exe_test_mod);
    exe_test_mod.addOptions("build_options", exe_options);
    exe_test_mod.addImport("grabber_protocol", grabber_protocol_mod);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_test_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    test_step.dependOn(&run_exe_unit_tests.step);

    // Integration tests in src/tests.zig
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkAgentFrameworks(b, tests_mod);
    addVersionImport(b, tests_mod);
    addGrabberPlistImports(b, tests_mod);
    tests_mod.addOptions("build_options", exe_options);
    tests_mod.addImport("grabber_protocol", grabber_protocol_mod);
    // The c.zig drift check @embedFile's tools/check_c_constants.c, which
    // lives outside src/. addAnonymousImport is the supported escape
    // hatch for embedding files outside the module's package root.
    tests_mod.addAnonymousImport("check_c_constants_c", .{
        .root_source_file = b.path("tools/check_c_constants.c"),
    });

    const tests_unit_tests = b.addTest(.{
        .root_module = tests_mod,
    });
    const run_tests_unit_tests = b.addRunArtifact(tests_unit_tests);
    test_step.dependOn(&run_tests_unit_tests.step);

    // Tests for individual modules
    const test_files = [_][]const u8{
        "src/Tokenizer.zig",
        "src/Parser.zig",
        "src/Mappings.zig",
        "src/Keycodes.zig",
        "src/EventTap.zig",
        "src/DeviceCheck.zig",
        "src/synthesize.zig",
        "src/grabber_cli.zig",
        "src/grabber_protocol.zig",
        "src/grabber/Vhidd.zig",
        "src/grabber/KbState.zig",
        "src/grabber/TapHold.zig",
        "src/grabber/HidSeize.zig",
        "src/grabber/PowerSourceNotify.zig",
        // "src/Hotload.zig", // Skip hot load test for local test only
    };

    for (test_files) |test_file| {
        const module = b.createModule(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });
        linkAgentFrameworks(b, module);
        addVersionImport(b, module);
        addGrabberPlistImports(b, module);
        module.addOptions("build_options", exe_options);
        // RuleSet's test imports the shared protocol module by name;
        // grabber_protocol.zig itself is the module's root, so it
        // doesn't need (and can't have) an import of itself.
        if (!std.mem.eql(u8, test_file, "src/grabber_protocol.zig")) {
            module.addImport("grabber_protocol", grabber_protocol_mod);
        }

        const module_tests = b.addTest(.{
            .root_module = module,
        });
        const run_module_tests = b.addRunArtifact(module_tests);
        test_step.dependOn(&run_module_tests.step);
    }
}
