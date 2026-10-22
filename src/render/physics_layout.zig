//! GPU physics buffer layouts: extern structs that mirror the structs in shaders/physics.msl byte for byte.

const std = @import("std");

// Every member on both sides is a 4-byte scalar (no float3, which MSL aligns to 16 bytes), so a
// member's MSL offset is 4 × its declaration index and the Zig extern layout matches with no hidden
// padding; the explicit _pad members fill each struct out to the stride the MSL side uses. Edit a
// struct here and in physics.msl together: the tests below pin the layout the kernels assume.

/// One entity's transform as the kernels read and write it (MSL GPUTransform, 32 B). Unlike the
/// ECS Transform, scale comes straight after the position.
pub const GPUTransform = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    scale: f32 = 1,
    rot_x: f32 = 0,
    rot_y: f32 = 0,
    rot_z: f32 = 0,
    _pad: f32 = 0,
};

/// Linear velocity (MSL GPUVelocity, 16 B).
pub const GPUVelocity = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    _pad: f32 = 0,
};

/// Box half extents plus a static flag (MSL GPUCollider, 16 B). is_static is a u32 (1 = static)
/// because bool has no fixed size across the CPU/GPU boundary.
pub const GPUCollider = extern struct {
    half_x: f32 = 0.5,
    half_y: f32 = 0.5,
    half_z: f32 = 0.5,
    is_static: u32 = 1,
};

/// World-space bounds written by compute_aabbs (MSL GPUAABB, 32 B).
pub const GPUAABB = extern struct {
    min_x: f32 = 0,
    min_y: f32 = 0,
    min_z: f32 = 0,
    _pad0: f32 = 0,
    max_x: f32 = 0,
    max_y: f32 = 0,
    max_z: f32 = 0,
    _pad1: f32 = 0,
};

/// One broad-phase overlap: the two entity slots and their per-axis penetration depth
/// (MSL CollisionPair, 24 B).
pub const CollisionPair = extern struct {
    a: u32 = 0,
    b: u32 = 0,
    pen_x: f32 = 0,
    pen_y: f32 = 0,
    pen_z: f32 = 0,
    _pad: f32 = 0,
};

/// Per-step kernel constants (MSL PhysicsParams, 16 B).
pub const PhysicsParams = extern struct {
    dt: f32 = 0,
    gravity: f32 = -15.0,
    entity_count: u32 = 0,
    _pad: u32 = 0,
};

// ============================================================
// TESTS — layout contract with shaders/physics.msl
// ============================================================

const testing = std.testing;

// Fails unless T is exactly these 4-byte members in this MSL declaration order: alignment 4, each
// member 4 bytes wide at offset 4 × index, and nothing else in the struct.
fn expectMslLayout(comptime T: type, comptime msl_members: []const []const u8) !void {
    try testing.expectEqual(4, @alignOf(T));
    try testing.expectEqual(msl_members.len * 4, @sizeOf(T));
    inline for (msl_members, 0..) |name, i| {
        try testing.expectEqual(4, @sizeOf(@FieldType(T, name)));
        try testing.expectEqual(i * 4, @offsetOf(T, name));
    }
}

test "GPU struct sizes match the MSL structs" {
    try testing.expectEqual(32, @sizeOf(GPUTransform));
    try testing.expectEqual(16, @sizeOf(GPUVelocity));
    try testing.expectEqual(16, @sizeOf(GPUCollider));
    try testing.expectEqual(32, @sizeOf(GPUAABB));
    try testing.expectEqual(24, @sizeOf(CollisionPair));
    try testing.expectEqual(16, @sizeOf(PhysicsParams));
}

test "GPU struct members sit at their MSL offsets" {
    try expectMslLayout(GPUTransform, &.{ "x", "y", "z", "scale", "rot_x", "rot_y", "rot_z", "_pad" });
    try expectMslLayout(GPUVelocity, &.{ "x", "y", "z", "_pad" });
    try expectMslLayout(GPUCollider, &.{ "half_x", "half_y", "half_z", "is_static" });
    try expectMslLayout(GPUAABB, &.{ "min_x", "min_y", "min_z", "_pad0", "max_x", "max_y", "max_z", "_pad1" });
    try expectMslLayout(CollisionPair, &.{ "a", "b", "pen_x", "pen_y", "pen_z", "_pad" });
    try expectMslLayout(PhysicsParams, &.{ "dt", "gravity", "entity_count", "_pad" });

    // The offsets the kernels lean on most, spelled out.
    try testing.expectEqual(12, @offsetOf(GPUTransform, "scale"));
    try testing.expectEqual(12, @offsetOf(GPUCollider, "is_static"));
    try testing.expectEqual(16, @offsetOf(GPUAABB, "max_x"));
    try testing.expectEqual(8, @offsetOf(CollisionPair, "pen_x"));
    try testing.expectEqual(8, @offsetOf(PhysicsParams, "entity_count"));
}

test "defaults mirror the ECS component defaults and GPU gravity" {
    const t: GPUTransform = .{};
    try testing.expectEqual(1, t.scale);
    const c: GPUCollider = .{};
    try testing.expectEqual(0.5, c.half_x);
    try testing.expectEqual(0.5, c.half_y);
    try testing.expectEqual(0.5, c.half_z);
    try testing.expectEqual(1, c.is_static);
    const p: PhysicsParams = .{};
    try testing.expectEqual(-15.0, p.gravity);
    try testing.expectEqual(0, p.entity_count);
}
