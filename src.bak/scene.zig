const std = @import("std");
const ecs = @import("ecs.zig");

// ============================================================
// SIMPLE SCENE (Array-based, kept for backward compat)
// ============================================================
pub const SceneObject = struct {
    x: f32,
    y: f32,
    z: f32,
    rot_y: f32 = 0,
};

pub const Scene = struct {
    objects: std.ArrayList(SceneObject),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Scene {
        return Scene{
            .objects = try std.ArrayList(SceneObject).initCapacity(allocator, 0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Scene) void {
        self.objects.deinit();
    }

    pub fn add(self: *Scene, x: f32, y: f32, z: f32) !void {
        try self.objects.append(self.allocator, .{ .x = x, .y = y, .z = z });
    }
};

// ============================================================
// ECS HELPERS
// ============================================================

/// Spawn a spinning renderable cube with collision at the given position.
pub fn spawnCube(world: *ecs.World, x: f32, y: f32, z: f32, spin_offset: f32) !ecs.Entity {
    const e = try world.spawn();

    world.setTransform(e, .{
        .x = x,
        .y = y,
        .z = z,
    });

    world.setSpin(e, .{
        .speed = 1.0,
        .offset = spin_offset,
    });

    world.setMeshRenderer(e, .{
        .mesh_id = 0,
        .texture_id = 0,
    });

    world.setCollider(e, .{
        .half_x = 0.5,
        .half_y = 0.5,
        .half_z = 0.5,
        .is_static = true,
    });

    return e;
}

/// Populate a field of spinning cubes.
pub fn spawnCubeField(world: *ecs.World, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const fi = @as(f32, @floatFromInt(i));
        const angle = fi * 0.5;
        const radius = 2.0 + (fi * 0.1);
        const x = @cos(angle) * radius;
        const y = (fi * 0.2) - 10.0;
        const z = @sin(angle) * radius - 10.0;
        const spin_offset = fi * 0.05;
        _ = try spawnCube(world, x, y, z, spin_offset);
    }
}
