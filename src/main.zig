const std = @import("std");
const Zetal = @import("Zetal");

pub fn main() !void {
    std.debug.print("Starting Zetal Engine...\n", .{});

    // 1. Initialize the Application
    const app = Zetal.window.App.init();

    // 2. Create a Window (800x600)
    const win = Zetal.window.Window.create(800, 600, "Zetal Engine");

    if (win) |w| {
        std.debug.print("Window created successfully: {any}\n", .{w.handle});
    } else {
        std.debug.print("Failed to create window!\n", .{});
        return;
    }

    std.debug.print("Entering Run Loop (Check your Dock!)\n", .{});

    // 3. Start the Event Loop (This blocks until the app quits)
    app.run();
}
