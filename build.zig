const std = @import("std");

fn linkFrameworks(exe: *std.Build.Step.Compile) void {
    exe.linkFramework("Cocoa");
    exe.linkFramework("Carbon");
    exe.linkFramework("CoreServices");
}

fn addVersionImport(b: *std.Build, exe: *std.Build.Step.Compile) void {
    // Get build mode string
    const mode_str = switch (exe.root_module.optimize.?) {
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

    const version_file = version_step.captureStdOut();
    exe.root_module.addAnonymousImport("VERSION", .{
        .root_source_file = version_file,
    });
}

const track_alloc_option = "track_alloc";

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe = b.addExecutable(.{
        .name = "skhd",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption(bool, track_alloc_option, false);

    linkFrameworks(exe);
    addVersionImport(b, exe);
    exe.root_module.addOptions("build_options", options);

    b.installArtifact(exe);

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

    const test_step = b.step("test", "Run unit tests");

    // Benchmark executable
    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = b.path("src/benchmark.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    linkFrameworks(bench_exe);
    addVersionImport(b, bench_exe);

    const zbench = b.dependency("zbench", .{
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_exe.root_module.addImport("zbench", zbench.module("zbench"));

    const bench_cmd = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);

    // Allocation tracking executable
    const alloc_exe = b.addExecutable(.{
        .name = "skhd-alloc",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkFrameworks(alloc_exe);
    addVersionImport(b, alloc_exe);

    const alloc_options = b.addOptions();
    alloc_options.addOption(bool, track_alloc_option, true);
    alloc_exe.root_module.addOptions("build_options", alloc_options);
    const alloc_cmd = b.addRunArtifact(alloc_exe);
    if (b.args) |args| {
        alloc_cmd.addArgs(args);
    }
    const alloc_step = b.step("alloc", "Run skhd with allocation logging");
    alloc_step.dependOn(&alloc_cmd.step);

    // Tests for main.zig
    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkFrameworks(exe_unit_tests);
    addVersionImport(b, exe_unit_tests);

    exe_unit_tests.root_module.addOptions("build_options", options);
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    test_step.dependOn(&run_exe_unit_tests.step);

    // Tests for tests.zig
    const tests_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkFrameworks(tests_unit_tests);
    addVersionImport(b, exe_unit_tests);
    tests_unit_tests.root_module.addOptions("build_options", options);
    const run_tests_unit_tests = b.addRunArtifact(tests_unit_tests);
    test_step.dependOn(&run_tests_unit_tests.step);

    // Tests for individual modules
    const test_files = [_][]const u8{
        "src/Tokenizer.zig",
        "src/Parser.zig",
        "src/Mappings.zig",
        "src/Keycodes.zig",
        "src/EventTap.zig",
        "src/synthesize.zig",
        // "src/Hotload.zig", // Skip hot load test for local test only
    };

    for (test_files) |test_file| {
        const module_tests = b.addTest(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });
        linkFrameworks(module_tests);
        addVersionImport(b, module_tests);
        module_tests.root_module.addOptions("build_options", options);
        const run_module_tests = b.addRunArtifact(module_tests);
        test_step.dependOn(&run_module_tests.step);
    }
}
