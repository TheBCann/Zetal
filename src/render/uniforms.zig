//! Uniform blocks for the scene and crosshair shaders: extern structs laid out byte for byte like their MSL twins.

const std = @import("std");

// The MSL side static_asserts these sizes and offsets against values pipelines.zig generates from
// the structs below, so a layout edit on either side fails at shader compile time.

/// Blinn-Phong light for fragment_main (MSL `LightUniforms`, 64 B). An MSL float3 is 16-byte aligned
/// and sized, hence the pad after every [3]f32.
pub const LightUniforms = extern struct {
    /// Point-light position the diffuse and specular terms shade towards (world space).
    light_pos: [3]f32,
    _pad0: f32 = 0,
    /// Camera position for the specular half vector (world space, unshaken).
    view_pos: [3]f32,
    _pad1: f32 = 0,
    /// Linear RGB light colour.
    light_color: [3]f32,
    _pad2: f32 = 0,
    ambient_strength: f32,
    specular_strength: f32,
    shininess: f32,
    _pad3: f32 = 0,
};

/// Sky parameters for skybox_fragment (MSL `SkyUniforms`, 16 B).
pub const SkyUniforms = extern struct {
    /// xyz = unit vector towards the sun disc, w = 0.
    sun_dir: [4]f32,
};

/// Crosshair overlay parameters for crosshair_vertex (MSL `CrosshairUniforms`, 16 B).
pub const CrosshairUniforms = extern struct {
    /// Drawable width / height; the shader divides x by it so the crosshair stays square.
    aspect: f32,
    /// Hit-marker timer: the marker shows while > 0 and pops outward as the value falls from 1.
    hit_marker: f32,
    _pad: [2]f32 = .{ 0, 0 },
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "LightUniforms matches the MSL float3 layout" {
    try testing.expectEqual(64, @sizeOf(LightUniforms));
    try testing.expectEqual(0, @offsetOf(LightUniforms, "light_pos"));
    try testing.expectEqual(16, @offsetOf(LightUniforms, "view_pos"));
    try testing.expectEqual(32, @offsetOf(LightUniforms, "light_color"));
    try testing.expectEqual(48, @offsetOf(LightUniforms, "ambient_strength"));
    try testing.expectEqual(52, @offsetOf(LightUniforms, "specular_strength"));
    try testing.expectEqual(56, @offsetOf(LightUniforms, "shininess"));
}

test "SkyUniforms and CrosshairUniforms are 16 bytes" {
    try testing.expectEqual(16, @sizeOf(SkyUniforms));
    try testing.expectEqual(16, @sizeOf(CrosshairUniforms));
    try testing.expectEqual(0, @offsetOf(CrosshairUniforms, "aspect"));
    try testing.expectEqual(4, @offsetOf(CrosshairUniforms, "hit_marker"));
}

test "padding defaults to zero so set*Bytes never ships stale bytes" {
    const light: LightUniforms = .{
        .light_pos = .{ 1, 2, 3 },
        .view_pos = .{ 4, 5, 6 },
        .light_color = .{ 1, 0.95, 0.9 },
        .ambient_strength = 0.15,
        .specular_strength = 0.5,
        .shininess = 32,
    };
    const floats: *const [16]f32 = @ptrCast(&light);
    try testing.expectEqualSlices(f32, &.{ 1, 2, 3, 0, 4, 5, 6, 0, 1, 0.95, 0.9, 0, 0.15, 0.5, 32, 0 }, floats);

    const crosshair: CrosshairUniforms = .{ .aspect = 1.5, .hit_marker = 0.25 };
    const words: *const [4]f32 = @ptrCast(&crosshair);
    try testing.expectEqualSlices(f32, &.{ 1.5, 0.25, 0, 0 }, words);
}
