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
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Code signing step
    const sign_cmd = b.addSystemCommand(&[_][]const u8{
        "sh",
        "scripts/codesign.sh",
    });
    const installed_exe = b.getInstallPath(.bin, exe.name);
    sign_cmd.addArg(installed_exe);
    sign_cmd.step.dependOn(b.getInstallStep());

    const sign_step = b.step("sign", "Code sign the binary (required for accessibility permissions on macOS 15+)");
    sign_step.dependOn(&sign_cmd.step);

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
