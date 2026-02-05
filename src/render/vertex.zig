const std = @import("std");

pub const Vertex = extern struct {
    position: [4]f32,
    color: [4]f32,
    // CHANGED: Use [4]f32 to force 16-byte alignment/stride (Total 48 bytes)
    uv: [4]f32,
};

// Helper to create UV with implicit padding
fn uv(u: f32, v: f32) [4]f32 {
    return .{ u, v, 0.0, 0.0 };
}

pub const triangle_vertices = [_]Vertex{
    // BASE
    .{ .position = .{ -0.5, -0.5, 0.5, 1.0 }, .color = .{ 1, 1, 1, 1 }, .uv = uv(0.0, 0.0) },
    .{ .position = .{ 0.5, -0.5, 0.5, 1.0 }, .color = .{ 1, 1, 1, 1 }, .uv = uv(1.0, 0.0) },
    .{ .position = .{ -0.5, -0.5, -0.5, 1.0 }, .color = .{ 1, 1, 1, 1 }, .uv = uv(0.0, 1.0) },

    .{ .position = .{ 0.5, -0.5, 0.5, 1.0 }, .color = .{ 1, 1, 1, 1 }, .uv = uv(1.0, 0.0) },
    .{ .position = .{ 0.5, -0.5, -0.5, 1.0 }, .color = .{ 1, 1, 1, 1 }, .uv = uv(1.0, 1.0) },
    .{ .position = .{ -0.5, -0.5, -0.5, 1.0 }, .color = .{ 1, 1, 1, 1 }, .uv = uv(0.0, 1.0) },

    // FRONT
    .{ .position = .{ 0.0, 0.5, 0.0, 1.0 }, .color = .{ 1, 0, 0, 1 }, .uv = uv(0.5, 0.0) },
    .{ .position = .{ -0.5, -0.5, 0.5, 1.0 }, .color = .{ 1, 0, 0, 1 }, .uv = uv(0.0, 1.0) },
    .{ .position = .{ 0.5, -0.5, 0.5, 1.0 }, .color = .{ 1, 0, 0, 1 }, .uv = uv(1.0, 1.0) },

    // RIGHT
    .{ .position = .{ 0.0, 0.5, 0.0, 1.0 }, .color = .{ 0, 1, 0, 1 }, .uv = uv(0.5, 0.0) },
    .{ .position = .{ 0.5, -0.5, 0.5, 1.0 }, .color = .{ 0, 1, 0, 1 }, .uv = uv(0.0, 1.0) },
    .{ .position = .{ 0.5, -0.5, -0.5, 1.0 }, .color = .{ 0, 1, 0, 1 }, .uv = uv(1.0, 1.0) },

    // BACK
    .{ .position = .{ 0.0, 0.5, 0.0, 1.0 }, .color = .{ 0, 0, 1, 1 }, .uv = uv(0.5, 0.0) },
    .{ .position = .{ 0.5, -0.5, -0.5, 1.0 }, .color = .{ 0, 0, 1, 1 }, .uv = uv(0.0, 1.0) },
    .{ .position = .{ -0.5, -0.5, -0.5, 1.0 }, .color = .{ 0, 0, 1, 1 }, .uv = uv(1.0, 1.0) },

    // LEFT
    .{ .position = .{ 0.0, 0.5, 0.0, 1.0 }, .color = .{ 1, 1, 0, 1 }, .uv = uv(0.5, 0.0) },
    .{ .position = .{ -0.5, -0.5, -0.5, 1.0 }, .color = .{ 1, 1, 0, 1 }, .uv = uv(0.0, 1.0) },
    .{ .position = .{ -0.5, -0.5, 0.5, 1.0 }, .color = .{ 1, 1, 0, 1 }, .uv = uv(1.0, 1.0) },
};
