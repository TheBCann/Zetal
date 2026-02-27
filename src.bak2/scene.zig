const std = @import("std");
const ecs = @import("ecs/world.zig");

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

/// Spawn a spinning renderable cube with collision (static).
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

/// Spawn a dynamic cube — has velocity (starts at zero), affected by gravity.
pub fn spawnDynamicCube(world: *ecs.World, x: f32, y: f32, z: f32) !ecs.Entity {
    const e = try world.spawn();

    world.setTransform(e, .{ .x = x, .y = y, .z = z });
    world.setMeshRenderer(e, .{ .mesh_id = 0, .texture_id = 0 });
    world.setVelocity(e, .{ .x = 0, .y = 0, .z = 0 }); // gravity pulls down
    world.setCollider(e, .{
        .half_x = 0.5,
        .half_y = 0.5,
        .half_z = 0.5,
        .is_static = false,
    });

    return e;
}

/// Populate a field of cubes: 70% static spiral + 30% dynamic falling from above.
pub fn spawnCubeField(world: *ecs.World, count: usize) !void {
    const static_count = count * 7 / 10;

    // --- Static spinning cubes in a spiral ---
    var i: usize = 0;
    while (i < static_count) : (i += 1) {
        const fi = @as(f32, @floatFromInt(i));
        const angle = fi * 0.5;
        const radius = 2.0 + (fi * 0.1);
        const x = @cos(angle) * radius;
        const y = (fi * 0.2) - 10.0;
        const z = @sin(angle) * radius - 10.0;
        const spin_offset = fi * 0.05;
        _ = try spawnCube(world, x, y, z, spin_offset);
    }

    // --- Dynamic cubes scattered above, will fall with gravity ---
    while (i < count) : (i += 1) {
        const fi = @as(f32, @floatFromInt(i - static_count));
        const x = @cos(fi * 1.7) * 4.0;
        const y = 5.0 + fi * 1.5; // staggered heights so they don't all land at once
        const z = @sin(fi * 1.3) * 4.0 - 10.0;
        _ = try spawnDynamicCube(world, x, y, z);
    }
}
