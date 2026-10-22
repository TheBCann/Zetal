//! Built-in render geometry: the shared vertex layout, the ground quad, the skybox cube and the crosshair overlay.

const std = @import("std");

/// One mesh vertex, laid out exactly like the MSL `Vertex` (four float4s, 64 bytes).
pub const Vertex = extern struct {
    position: [4]f32,
    color: [4]f32,
    uv: [4]f32,
    normal: [4]f32,
};

// ============================================================
// Ground quad
// ============================================================

/// World-space height of the ground plane.
pub const GROUND_Y: f32 = -12.0;
/// Half the side of the square ground quad (it spans ±50 on x and z).
pub const GROUND_HALF_EXTENT: f32 = 50.0;

const GROUND_COLOR: [4]f32 = .{ 0.3, 0.35, 0.3, 1 };
const GROUND_NORMAL: [4]f32 = .{ 0, 1, 0, 0 };

/// The ground quad's corners; the albedo texture repeats 10 times along each side.
pub const ground_vertices: [4]Vertex = .{
    .{ .position = .{ -GROUND_HALF_EXTENT, GROUND_Y, -GROUND_HALF_EXTENT, 1 }, .color = GROUND_COLOR, .uv = .{ 0, 0, 0, 0 }, .normal = GROUND_NORMAL },
    .{ .position = .{ GROUND_HALF_EXTENT, GROUND_Y, -GROUND_HALF_EXTENT, 1 }, .color = GROUND_COLOR, .uv = .{ 10, 0, 0, 0 }, .normal = GROUND_NORMAL },
    .{ .position = .{ GROUND_HALF_EXTENT, GROUND_Y, GROUND_HALF_EXTENT, 1 }, .color = GROUND_COLOR, .uv = .{ 10, 10, 0, 0 }, .normal = GROUND_NORMAL },
    .{ .position = .{ -GROUND_HALF_EXTENT, GROUND_Y, GROUND_HALF_EXTENT, 1 }, .color = GROUND_COLOR, .uv = .{ 0, 10, 0, 0 }, .normal = GROUND_NORMAL },
};

/// Two triangles over `ground_vertices`, clockwise seen from above. Do not reorder: with this winding the
/// shadow pass culls the ground, which keeps it out of the shadow map exactly like the original.
pub const ground_indices: [6]u32 = .{ 0, 1, 2, 0, 2, 3 };

// ============================================================
// Skybox
// ============================================================

/// Unit cube around the camera: 12 triangles as float4 positions (w = 1), two per face.
pub const skybox_vertices: [36][4]f32 = .{
    // +Z face
    .{ -1, 1, 1, 1 },  .{ -1, -1, 1, 1 },  .{ 1, -1, 1, 1 },
    .{ -1, 1, 1, 1 },  .{ 1, -1, 1, 1 },   .{ 1, 1, 1, 1 },
    // -Z face
    .{ 1, 1, -1, 1 },  .{ 1, -1, -1, 1 },  .{ -1, -1, -1, 1 },
    .{ 1, 1, -1, 1 },  .{ -1, -1, -1, 1 }, .{ -1, 1, -1, 1 },
    // +X face
    .{ 1, 1, 1, 1 },   .{ 1, -1, 1, 1 },   .{ 1, -1, -1, 1 },
    .{ 1, 1, 1, 1 },   .{ 1, -1, -1, 1 },  .{ 1, 1, -1, 1 },
    // -X face
    .{ -1, 1, -1, 1 }, .{ -1, -1, -1, 1 }, .{ -1, -1, 1, 1 },
    .{ -1, 1, -1, 1 }, .{ -1, -1, 1, 1 },  .{ -1, 1, 1, 1 },
    // +Y face (ceiling)
    .{ -1, 1, -1, 1 }, .{ -1, 1, 1, 1 },   .{ 1, 1, 1, 1 },
    .{ -1, 1, -1, 1 }, .{ 1, 1, 1, 1 },    .{ 1, 1, -1, 1 },
    // -Y face (floor)
    .{ -1, -1, 1, 1 }, .{ -1, -1, -1, 1 }, .{ 1, -1, -1, 1 },
    .{ -1, -1, 1, 1 }, .{ 1, -1, -1, 1 },  .{ 1, -1, 1, 1 },
};

// ============================================================
// Crosshair and hit marker (NDC, drawn last without depth testing)
// ============================================================

// Crosshair: four arms around a central gap, plus a centre dot.
const ARM_LEN: f32 = 0.020;
const ARM_GAP: f32 = 0.006;
const ARM_THICK: f32 = 0.0015;
const DOT_HALF: f32 = 0.0015;
const ARM_END: f32 = ARM_GAP + ARM_LEN;

// Hit marker: a thinner 'X', built axis-aligned and rotated 45° by `hitMarkerVertex`.
const HM_GAP: f32 = 0.015;
const HM_LEN: f32 = 0.015;
const HM_THICK: f32 = 0.001;
const HM_END: f32 = HM_GAP + HM_LEN;

/// Rotates a hit-marker corner by 45° and tags it w = 2, which the crosshair shader keys on to show it
/// only while the hit marker is active (the crosshair itself has w = 1).
fn hitMarkerVertex(x: f32, y: f32) [4]f32 {
    const c45: f32 = 0.70710678;
    return .{ (x - y) * c45, (x + y) * c45, 0.0, 2.0 };
}

const crosshair_arm_vertices: [30][4]f32 = .{
    // Left arm
    .{ -ARM_END, -ARM_THICK, 0, 1 }, .{ -ARM_GAP, -ARM_THICK, 0, 1 }, .{ -ARM_GAP, ARM_THICK, 0, 1 },
    .{ -ARM_END, -ARM_THICK, 0, 1 }, .{ -ARM_GAP, ARM_THICK, 0, 1 },  .{ -ARM_END, ARM_THICK, 0, 1 },
    // Right arm
    .{ ARM_GAP, -ARM_THICK, 0, 1 },  .{ ARM_END, -ARM_THICK, 0, 1 },  .{ ARM_END, ARM_THICK, 0, 1 },
    .{ ARM_GAP, -ARM_THICK, 0, 1 },  .{ ARM_END, ARM_THICK, 0, 1 },   .{ ARM_GAP, ARM_THICK, 0, 1 },
    // Top arm
    .{ -ARM_THICK, ARM_GAP, 0, 1 },  .{ ARM_THICK, ARM_GAP, 0, 1 },   .{ ARM_THICK, ARM_END, 0, 1 },
    .{ -ARM_THICK, ARM_GAP, 0, 1 },  .{ ARM_THICK, ARM_END, 0, 1 },   .{ -ARM_THICK, ARM_END, 0, 1 },
    // Bottom arm
    .{ -ARM_THICK, -ARM_END, 0, 1 }, .{ ARM_THICK, -ARM_END, 0, 1 },  .{ ARM_THICK, -ARM_GAP, 0, 1 },
    .{ -ARM_THICK, -ARM_END, 0, 1 }, .{ ARM_THICK, -ARM_GAP, 0, 1 },  .{ -ARM_THICK, -ARM_GAP, 0, 1 },
    // Centre dot
    .{ -DOT_HALF, -DOT_HALF, 0, 1 }, .{ DOT_HALF, -DOT_HALF, 0, 1 },  .{ DOT_HALF, DOT_HALF, 0, 1 },
    .{ -DOT_HALF, -DOT_HALF, 0, 1 }, .{ DOT_HALF, DOT_HALF, 0, 1 },   .{ -DOT_HALF, DOT_HALF, 0, 1 },
};

const hit_marker_vertices: [24][4]f32 = .{
    // Top-right arm
    hitMarkerVertex(HM_GAP, -HM_THICK),  hitMarkerVertex(HM_END, -HM_THICK),  hitMarkerVertex(HM_END, HM_THICK),
    hitMarkerVertex(HM_GAP, -HM_THICK),  hitMarkerVertex(HM_END, HM_THICK),   hitMarkerVertex(HM_GAP, HM_THICK),
    // Bottom-left arm
    hitMarkerVertex(-HM_END, -HM_THICK), hitMarkerVertex(-HM_GAP, -HM_THICK), hitMarkerVertex(-HM_GAP, HM_THICK),
    hitMarkerVertex(-HM_END, -HM_THICK), hitMarkerVertex(-HM_GAP, HM_THICK),  hitMarkerVertex(-HM_END, HM_THICK),
    // Top-left arm
    hitMarkerVertex(-HM_THICK, HM_GAP),  hitMarkerVertex(HM_THICK, HM_GAP),   hitMarkerVertex(HM_THICK, HM_END),
    hitMarkerVertex(-HM_THICK, HM_GAP),  hitMarkerVertex(HM_THICK, HM_END),   hitMarkerVertex(-HM_THICK, HM_END),
    // Bottom-right arm
    hitMarkerVertex(-HM_THICK, -HM_END), hitMarkerVertex(HM_THICK, -HM_END),  hitMarkerVertex(HM_THICK, -HM_GAP),
    hitMarkerVertex(-HM_THICK, -HM_END), hitMarkerVertex(HM_THICK, -HM_GAP),  hitMarkerVertex(-HM_THICK, -HM_GAP),
};

/// Crosshair overlay triangles: 30 crosshair vertices (w = 1) followed by 24 hit-marker vertices (w = 2).
pub const crosshair_vertices: [54][4]f32 = crosshair_arm_vertices ++ hit_marker_vertices;

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "Vertex matches the MSL layout" {
    try testing.expectEqual(64, @sizeOf(Vertex));
    try testing.expectEqual(0, @offsetOf(Vertex, "position"));
    try testing.expectEqual(16, @offsetOf(Vertex, "color"));
    try testing.expectEqual(32, @offsetOf(Vertex, "uv"));
    try testing.expectEqual(48, @offsetOf(Vertex, "normal"));
}

test "geometry sizes and counts" {
    try testing.expectEqual(4, ground_vertices.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 0, 2, 3 }, &ground_indices);
    try testing.expectEqual(36, skybox_vertices.len);
    try testing.expectEqual(54, crosshair_vertices.len);
    try testing.expectEqual(16 * 36, @sizeOf(@TypeOf(skybox_vertices)));
    try testing.expectEqual(16 * 54, @sizeOf(@TypeOf(crosshair_vertices)));
}

test "ground quad: flat at GROUND_Y, spans the half extent, faces up" {
    for (ground_vertices) |v| {
        try testing.expectEqual(GROUND_Y, v.position[1]);
        try testing.expectEqual(GROUND_HALF_EXTENT, @abs(v.position[0]));
        try testing.expectEqual(GROUND_HALF_EXTENT, @abs(v.position[2]));
        try testing.expectEqual(1, v.position[3]);
        try testing.expectEqualSlices(f32, &.{ 0.3, 0.35, 0.3, 1 }, &v.color);
        try testing.expectEqualSlices(f32, &.{ 0, 1, 0, 0 }, &v.normal);
    }
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0 }, &ground_vertices[0].uv);
    try testing.expectEqualSlices(f32, &.{ 10, 10, 0, 0 }, &ground_vertices[2].uv);
}

test "ground triangles wind clockwise seen from above" {
    // A right-handed (b - a) x (c - a) pointing down means the triangle looks clockwise from +y.
    var t: usize = 0;
    while (t < ground_indices.len) : (t += 3) {
        const a = ground_vertices[ground_indices[t]].position;
        const b = ground_vertices[ground_indices[t + 1]].position;
        const c = ground_vertices[ground_indices[t + 2]].position;
        const ab = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
        const ac = [3]f32{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
        const normal_y = ab[2] * ac[0] - ab[0] * ac[2];
        try testing.expect(normal_y < 0);
    }
}

test "skybox: every vertex is a unit-cube corner" {
    for (skybox_vertices) |v| {
        for (v[0..3]) |coord| try testing.expectEqual(1, @abs(coord));
        try testing.expectEqual(1, v[3]);
    }
}

test "crosshair: w == 1 for the first 30 vertices, w == 2 for the hit marker" {
    for (crosshair_vertices, 0..) |v, i| {
        try testing.expectEqual(@as(f32, if (i < 30) 1 else 2), v[3]);
        try testing.expectEqual(0, v[2]);
    }
}

test "crosshair: arms and hit marker positions" {
    // First left-arm vertex sits at the arm's outer end, just below the centre line.
    try testing.expectApproxEqAbs(@as(f32, -0.026), crosshair_vertices[0][0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.0015), crosshair_vertices[0][1], 1e-6);
    // First hit-marker vertex: (gap, -thick) rotated 45° counter-clockwise.
    const c45: f32 = 0.70710678;
    try testing.expectApproxEqAbs((HM_GAP + HM_THICK) * c45, crosshair_vertices[30][0], 1e-6);
    try testing.expectApproxEqAbs((HM_GAP - HM_THICK) * c45, crosshair_vertices[30][1], 1e-6);
    // The top-right arm stays on the +x/+y diagonal.
    for (crosshair_vertices[30..36]) |v| {
        try testing.expect(v[0] > 0 and v[1] > 0);
    }
}
