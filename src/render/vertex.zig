const std = @import("std");

pub const Vertex = extern struct {
    position: [4]f32,
    color: [4]f32,
    uv: [4]f32,
    normal: [4]f32, // NEW: Surface Normal vector (padded to 16 bytes)
};

fn uv(u: f32, v: f32) [4]f32 {
    return .{ u, v, 0.0, 0.0 };
}

// Normals point perpendicular to the triangle face
// Base points Down (0, -1, 0)
// Sides point Outward and slightly Up (0, 0.5, 1.0) normalized
const N_DOWN = [4]f32{ 0.0, -1.0, 0.0, 0.0 };
const N_FRONT = [4]f32{ 0.0, 0.447, 0.894, 0.0 }; // (0, 0.5, 1) normalized
const N_RIGHT = [4]f32{ 0.894, 0.447, 0.0, 0.0 }; // (1, 0.5, 0) normalized
const N_BACK = [4]f32{ 0.0, 0.447, -0.894, 0.0 }; // (0, 0.5, -1) normalized
const N_LEFT = [4]f32{ -0.894, 0.447, 0.0, 0.0 }; // (-1, 0.5, 0) normalized

pub const triangle_vertices = [_]Vertex{
    // BASE (Dark)
    .{ .position = .{ -0.5, -0.5, 0.5, 1.0 }, .color = .{ 1, 1, 1, 1 }, .uv = uv(0.0, 0.0), .normal = N_DOWN },
    .{ .position = .{ 0.5, -0.5, 0.5, 1.0 }, .color = .{ 1, 1, 1, 1 }, .uv = uv(1.0, 0.0), .normal = N_DOWN },
    .{ .position = .{ -0.5, -0.5, -0.5, 1.0 }, .color = .{ 1, 1, 1, 1 }, .uv = uv(0.0, 1.0), .normal = N_DOWN },
    .{ .position = .{ 0.5, -0.5, 0.5, 1.0 }, .color = .{ 1, 1, 1, 1 }, .uv = uv(1.0, 0.0), .normal = N_DOWN },
    .{ .position = .{ 0.5, -0.5, -0.5, 1.0 }, .color = .{ 1, 1, 1, 1 }, .uv = uv(1.0, 1.0), .normal = N_DOWN },
    .{ .position = .{ -0.5, -0.5, -0.5, 1.0 }, .color = .{ 1, 1, 1, 1 }, .uv = uv(0.0, 1.0), .normal = N_DOWN },

    // FRONT
    .{ .position = .{ 0.0, 0.5, 0.0, 1.0 }, .color = .{ 1, 0, 0, 1 }, .uv = uv(0.5, 0.0), .normal = N_FRONT },
    .{ .position = .{ -0.5, -0.5, 0.5, 1.0 }, .color = .{ 1, 0, 0, 1 }, .uv = uv(0.0, 1.0), .normal = N_FRONT },
    .{ .position = .{ 0.5, -0.5, 0.5, 1.0 }, .color = .{ 1, 0, 0, 1 }, .uv = uv(1.0, 1.0), .normal = N_FRONT },

    // RIGHT
    .{ .position = .{ 0.0, 0.5, 0.0, 1.0 }, .color = .{ 0, 1, 0, 1 }, .uv = uv(0.5, 0.0), .normal = N_RIGHT },
    .{ .position = .{ 0.5, -0.5, 0.5, 1.0 }, .color = .{ 0, 1, 0, 1 }, .uv = uv(0.0, 1.0), .normal = N_RIGHT },
    .{ .position = .{ 0.5, -0.5, -0.5, 1.0 }, .color = .{ 0, 1, 0, 1 }, .uv = uv(1.0, 1.0), .normal = N_RIGHT },

    // BACK
    .{ .position = .{ 0.0, 0.5, 0.0, 1.0 }, .color = .{ 0, 0, 1, 1 }, .uv = uv(0.5, 0.0), .normal = N_BACK },
    .{ .position = .{ 0.5, -0.5, -0.5, 1.0 }, .color = .{ 0, 0, 1, 1 }, .uv = uv(0.0, 1.0), .normal = N_BACK },
    .{ .position = .{ -0.5, -0.5, -0.5, 1.0 }, .color = .{ 0, 0, 1, 1 }, .uv = uv(1.0, 1.0), .normal = N_BACK },

    // LEFT
    .{ .position = .{ 0.0, 0.5, 0.0, 1.0 }, .color = .{ 1, 1, 0, 1 }, .uv = uv(0.5, 0.0), .normal = N_LEFT },
    .{ .position = .{ -0.5, -0.5, -0.5, 1.0 }, .color = .{ 1, 1, 0, 1 }, .uv = uv(0.0, 1.0), .normal = N_LEFT },
    .{ .position = .{ -0.5, -0.5, 0.5, 1.0 }, .color = .{ 1, 1, 0, 1 }, .uv = uv(1.0, 1.0), .normal = N_LEFT },
};
