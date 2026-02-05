const std = @import("std");

pub const Vertex = extern struct {
    position: [4]f32, // Changed to 4 floats for 16-byte alignment
    color: [4]f32,
};

// Define the Triangle geometry
pub const triangle_vertices = [_]Vertex{
    // Top (Red) -- Added 4th float (1.0) to position
    .{ .position = .{ 0.0, 0.5, 0.0, 1.0 }, .color = .{ 1.0, 0.0, 0.0, 1.0 } },
    // Bottom Left (Green)
    .{ .position = .{ -0.5, -0.5, 0.0, 1.0 }, .color = .{ 0.0, 1.0, 0.0, 1.0 } },
    // Bottom Right (Blue)
    .{ .position = .{ 0.5, -0.5, 0.0, 1.0 }, .color = .{ 0.0, 0.0, 1.0, 1.0 } },
};
