const std = @import("std");

fn linkFrameworks(exe: *std.Build.Step.Compile) void {
    exe.linkFramework("Cocoa");
    exe.linkFramework("Carbon");
    exe.linkFramework("CoreServices");
}

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "skhd",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkFrameworks(exe);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Create a test step that will run all tests
    // Note: If tests hang, run with ZIG_PROGRESS=0 environment variable
    // or use the test.sh script. This disables the Zig progress server
    // which can cause issues with parallel test execution.
    const test_step = b.step("test", "Run unit tests");

    // Add test for main module and all imported modules
    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkFrameworks(exe_unit_tests);
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    test_step.dependOn(&run_exe_unit_tests.step);

    // Add dedicated test file
    const tests_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkFrameworks(tests_unit_tests);
    test_step.dependOn(&tests_unit_tests.step);

    // Add tests for individual modules that may have their own test blocks
    const test_files = [_][]const u8{
        "src/Tokenizer.zig",
        "src/Parser.zig",
        "src/Mappings.zig",
        "src/Keycodes.zig",
        "src/EventTap.zig",
        "src/synthesize.zig",
        "src/Logger.zig",
    };

    for (test_files) |test_file| {
        const module_tests = b.addTest(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });
        linkFrameworks(module_tests);
        test_step.dependOn(&module_tests.step);
    }
}
