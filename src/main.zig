const std = @import("std");

extern "Metal" fn MTLCreateSystemDefaultDevice() ?*anyopaque;

pub fn main() !void {
    std.debug.print("Initializing Zetal Engine...\n", .{});

    // 1. Ask macOS for the default GPU (Apple Silicon)
    const device = MTLCreateSystemDefaultDevice();

    if (device) |d| {
        std.debug.print("SUCCESS: Metal Device Found: {any}\n", .{d});
    } else {
        std.debug.print("ERROR: Failed to create Metal Device (Are you on macOS?)\n", .{});
    }
}
