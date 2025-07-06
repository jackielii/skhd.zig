const std = @import("std");

fn linkFrameworks(exe: *std.Build.Step.Compile) void {
    exe.linkFramework("Cocoa");
    exe.linkFramework("Carbon");
    exe.linkFramework("CoreServices");
}

fn configureExecutable(b: *std.Build, exe: *std.Build.Step.Compile, options: *std.Build.Step.Options) void {
    linkFrameworks(exe);

    // Add VERSION file to the module
    exe.root_module.addAnonymousImport("VERSION", .{
        .root_source_file = b.path("VERSION"),
    });

    // Add build options
    exe.root_module.addOptions("build_options", options);
}

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "skhd",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption(bool, "enable_alloc_logging", false);
    configureExecutable(b, exe, options);

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");

    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = b.path("src/benchmark.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    linkFrameworks(bench_exe);

    const zbench = b.dependency("zbench", .{
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_exe.root_module.addImport("zbench", zbench.module("zbench"));

    const bench_cmd = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);

    const alloc_exe = b.addExecutable(.{
        .name = "skhd-alloc",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const alloc_options = b.addOptions();
    alloc_options.addOption(bool, "track_alloc", true);

    configureExecutable(b, alloc_exe, alloc_options);
    const alloc_cmd = b.addRunArtifact(alloc_exe);
    if (b.args) |args| {
        alloc_cmd.addArgs(args);
    }
    const alloc_step = b.step("alloc", "Run skhd with allocation logging");
    alloc_step.dependOn(&alloc_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureExecutable(b, exe_unit_tests, options);
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    test_step.dependOn(&run_exe_unit_tests.step);
    const tests_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureExecutable(b, tests_unit_tests, options);
    const run_tests_unit_tests = b.addRunArtifact(tests_unit_tests);
    test_step.dependOn(&run_tests_unit_tests.step);

    // Add tests for individual modules that may have their own test blocks
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
        configureExecutable(b, module_tests, options);
        const run_module_tests = b.addRunArtifact(module_tests);
        test_step.dependOn(&run_module_tests.step);
    }
}
