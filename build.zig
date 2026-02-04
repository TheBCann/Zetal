const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Create the module
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 2. Link Frameworks to the MODULE (New API)
    // We pass .{} because the third argument 'options' is mandatory now
    root_module.linkFramework("Foundation", .{});
    root_module.linkFramework("Metal", .{});
    root_module.linkFramework("AppKit", .{});

    // 3. Create the executable using the module
    const exe = b.addExecutable(.{
        .name = "Zetal",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
