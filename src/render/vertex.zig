const std = @import("std");

pub const Vertex = extern struct {
    position: [4]f32,
    color: [4]f32,
};

pub const triangle_vertices = [_]Vertex{
    // BASE (Dark Gray) - Triangle 1
    .{ .position = .{ -0.5, -0.5, 0.5, 1.0 }, .color = .{ 0.2, 0.2, 0.2, 1.0 } },
    .{ .position = .{ 0.5, -0.5, 0.5, 1.0 }, .color = .{ 0.2, 0.2, 0.2, 1.0 } },
    .{ .position = .{ -0.5, -0.5, -0.5, 1.0 }, .color = .{ 0.2, 0.2, 0.2, 1.0 } },
    // BASE (Dark Gray) - Triangle 2
    .{ .position = .{ 0.5, -0.5, 0.5, 1.0 }, .color = .{ 0.2, 0.2, 0.2, 1.0 } },
    .{ .position = .{ 0.5, -0.5, -0.5, 1.0 }, .color = .{ 0.2, 0.2, 0.2, 1.0 } },
    .{ .position = .{ -0.5, -0.5, -0.5, 1.0 }, .color = .{ 0.2, 0.2, 0.2, 1.0 } },

    // FRONT FACE (Red)
    .{ .position = .{ 0.0, 0.5, 0.0, 1.0 }, .color = .{ 1.0, 0.0, 0.0, 1.0 } }, // Top
    .{ .position = .{ -0.5, -0.5, 0.5, 1.0 }, .color = .{ 1.0, 0.0, 0.0, 1.0 } }, // Left
    .{ .position = .{ 0.5, -0.5, 0.5, 1.0 }, .color = .{ 1.0, 0.0, 0.0, 1.0 } }, // Right

    // RIGHT FACE (Green)
    .{ .position = .{ 0.0, 0.5, 0.0, 1.0 }, .color = .{ 0.0, 1.0, 0.0, 1.0 } }, // Top
    .{ .position = .{ 0.5, -0.5, 0.5, 1.0 }, .color = .{ 0.0, 1.0, 0.0, 1.0 } }, // Left
    .{ .position = .{ 0.5, -0.5, -0.5, 1.0 }, .color = .{ 0.0, 1.0, 0.0, 1.0 } }, // Right

    // BACK FACE (Blue)
    .{ .position = .{ 0.0, 0.5, 0.0, 1.0 }, .color = .{ 0.0, 0.0, 1.0, 1.0 } }, // Top
    .{ .position = .{ 0.5, -0.5, -0.5, 1.0 }, .color = .{ 0.0, 0.0, 1.0, 1.0 } }, // Left
    .{ .position = .{ -0.5, -0.5, -0.5, 1.0 }, .color = .{ 0.0, 0.0, 1.0, 1.0 } }, // Right

    // LEFT FACE (Yellow)
    .{ .position = .{ 0.0, 0.5, 0.0, 1.0 }, .color = .{ 1.0, 1.0, 0.0, 1.0 } }, // Top
    .{ .position = .{ -0.5, -0.5, -0.5, 1.0 }, .color = .{ 1.0, 1.0, 0.0, 1.0 } }, // Left
    .{ .position = .{ -0.5, -0.5, 0.5, 1.0 }, .color = .{ 1.0, 1.0, 0.0, 1.0 } }, // Right
};
