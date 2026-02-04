const std = @import("std");
const Zetal = @import("Zetal");

pub fn main() !void {
    std.debug.print("Starting Zetal Engine...\n", .{});

    // 1. Initialize Metal Device (GPU)
    // We need this BEFORE the view so we can give the view a GPU to draw with.
    const device = Zetal.MetalDevice.createSystemDefault();
    if (device == null) {
        std.debug.print("CRITICAL ERROR: No Metal Device Found.\n", .{});
        return;
    }
    std.debug.print("GPU Initialized: {s}\n", .{device.?.getName().?});

    // 2. Initialize App
    const app = Zetal.window.App.init();

    // 3. Create Window
    const width = 800;
    const height = 600;
    const win = Zetal.window.Window.create(width, height, "Zetal Engine");

    if (win) |w| {
        // 4. Create the Metal View and attach it
        const rect = Zetal.window.Rect{ .origin_x = 0, .origin_y = 0, .width = width, .height = height };

        // Pass the raw device handle to the view
        const view = Zetal.window.MetalView.create(rect, device.?.handle);

        if (view) |v| {
            w.setContentView(v);
            std.debug.print("Metal Layer Attached Successfully.\n", .{});
        }
    } else {
        std.debug.print("Failed to create window!\n", .{});
        return;
    }

    std.debug.print("Entering Run Loop...\n", .{});
    app.run();
}
