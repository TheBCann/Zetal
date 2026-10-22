//! Build graph: the Zetal engine library, the Zetal game executable, and the run and test steps.
const std = @import("std");

/// Declares the library module, the executable and the `run` and `test` steps.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ?std.lang.Optimize: null (no -Doptimize / --release) means Debug; passed straight through.
    const optimize = b.standardOptimizeOption(.{});

    // ============================================================
    // 1. THE LIBRARY (Zetal engine, src/root.zig)
    // ============================================================
    const zetal = b.addModule("Zetal", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        // So the library's own test binary follows -Doptimize too.
        .optimize = optimize,
    });
    // AppKit, MetalKit and QuartzCore classes are only reached through objc_getClass at run time, so
    // no symbol pulls those frameworks in: `.needed` stops the linker from dropping them.
    zetal.linkFramework("Foundation", .{});
    zetal.linkFramework("AppKit", .{ .needed = true });
    zetal.linkFramework("Metal", .{});
    zetal.linkFramework("MetalKit", .{ .needed = true });
    zetal.linkFramework("QuartzCore", .{ .needed = true });
    zetal.linkSystemLibrary("objc", .{});

    // ============================================================
    // 2. THE APP (the shooting-gallery game, src/main.zig)
    // ============================================================
    const exe = b.addExecutable(.{
        .name = "Zetal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "Zetal", .module = zetal }},
        }),
    });
    b.installArtifact(exe);

    // ============================================================
    // 3. RUN STEP (`zig build run -- --frames 240` passes the args through)
    // ============================================================
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // The game loads assets/ relative to the cwd: run it from the repo root, wherever zig is invoked.
    run_cmd.setCwd(b.path(""));
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Build and launch the game");
    run_step.dependOn(&run_cmd.step);

    // ============================================================
    // 4. TEST STEP (the library's tests and the executable's own tests)
    // ============================================================
    const metal_validation = b.option(
        bool,
        "metal-validation",
        "Run the tests under Metal API and shader validation, aborting on any Metal warning",
    ) orelse false;
    const test_step = b.step("test", "Run unit tests");
    const test_runs = [_]*std.Build.Step.Run{
        b.addRunArtifact(b.addTest(.{ .root_module = zetal })),
        b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })),
    };
    for (test_runs) |run| {
        // Set on the step, not inherited from the shell: a passing test run is cached, and only the
        // step's own environment is part of its cache key, so `MTL_...=1 zig build test` after a plain
        // pass would silently reuse that pass without running anything.
        if (metal_validation) {
            run.setEnvironmentVariable("MTL_DEBUG_LAYER", "1");
            run.setEnvironmentVariable("MTL_DEBUG_LAYER_WARNING_MODE", "assert");
            run.setEnvironmentVariable("MTL_SHADER_VALIDATION", "1");
        }
        test_step.dependOn(&run.step);
    }
}
