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

/// Spawn a static cube without spin (for walls/targets).
pub fn spawnStaticCube(world: *ecs.World, x: f32, y: f32, z: f32) !ecs.Entity {
    const e = try world.spawn();

    world.setTransform(e, .{ .x = x, .y = y, .z = z });
    world.setMeshRenderer(e, .{ .mesh_id = 0, .texture_id = 0 });
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
    world.setVelocity(e, .{ .x = 0, .y = 0, .z = 0 });
    world.setCollider(e, .{
        .half_x = 0.5,
        .half_y = 0.5,
        .half_z = 0.5,
        .is_static = false,
    });

    return e;
}

/// Spawn a projectile — small fast cube fired from camera.
/// Uses half-size (0.25) collider to distinguish from regular cubes.
pub fn spawnProjectile(
    world: *ecs.World,
    x: f32,
    y: f32,
    z: f32,
    vx: f32,
    vy: f32,
    vz: f32,
) !ecs.Entity {
    const e = try world.spawn();

    world.setTransform(e, .{ .x = x, .y = y, .z = z, .scale = 0.5 });
    world.setMeshRenderer(e, .{ .mesh_id = 0, .texture_id = 0 });
    world.setVelocity(e, .{ .x = vx, .y = vy, .z = vz });
    world.setCollider(e, .{
        .half_x = 0.25,
        .half_y = 0.25,
        .half_z = 0.25,
        .is_static = false,
    });

    return e;
}

// ============================================================
// FPS SCENE — Target walls + scattered cubes to shoot at
// ============================================================

/// Build an FPS shooting gallery: walls of static cubes as targets.
pub fn spawnFPSScene(world: *ecs.World) !void {
    // --- Back wall (5x5 grid at z = -20) ---
    var row: i32 = 0;
    while (row < 5) : (row += 1) {
        var col: i32 = 0;
        while (col < 5) : (col += 1) {
            const x = @as(f32, @floatFromInt(col - 2)) * 1.1;
            const y = @as(f32, @floatFromInt(row)) * 1.1 - 9.5;
            _ = try spawnStaticCube(world, x, y, -20.0);
        }
    }

    // --- Left wall (3x4 at x = -8) ---
    row = 0;
    while (row < 4) : (row += 1) {
        var col: i32 = 0;
        while (col < 3) : (col += 1) {
            const z = @as(f32, @floatFromInt(col)) * 1.1 - 15.0;
            const y = @as(f32, @floatFromInt(row)) * 1.1 - 9.5;
            _ = try spawnStaticCube(world, -8.0, y, z);
        }
    }

    // --- Right wall (3x4 at x = 8) ---
    row = 0;
    while (row < 4) : (row += 1) {
        var col: i32 = 0;
        while (col < 3) : (col += 1) {
            const z = @as(f32, @floatFromInt(col)) * 1.1 - 15.0;
            const y = @as(f32, @floatFromInt(row)) * 1.1 - 9.5;
            _ = try spawnStaticCube(world, 8.0, y, z);
        }
    }

    // --- Tower (1x8 stack at center-back) ---
    row = 0;
    while (row < 8) : (row += 1) {
        const y = @as(f32, @floatFromInt(row)) * 1.1 - 9.5;
        _ = try spawnStaticCube(world, 0.0, y, -12.0);
    }

    // --- Pyramid (stacked rows) ---
    var level: i32 = 0;
    while (level < 4) : (level += 1) {
        const width = 4 - level;
        var c: i32 = 0;
        while (c < width) : (c += 1) {
            const x = @as(f32, @floatFromInt(c)) * 1.1 - @as(f32, @floatFromInt(width - 1)) * 0.55 + 5.0;
            const y = @as(f32, @floatFromInt(level)) * 1.1 - 9.5;
            _ = try spawnStaticCube(world, x, y, -16.0);
        }
    }

    // --- Scattered elevated targets ---
    _ = try spawnStaticCube(world, -4.0, -6.0, -18.0);
    _ = try spawnStaticCube(world, 3.0, -5.0, -14.0);
    _ = try spawnStaticCube(world, -2.0, -4.0, -10.0);
    _ = try spawnStaticCube(world, 6.0, -7.0, -22.0);
}

/// Legacy: Populate a field of cubes: 70% static spiral + 30% dynamic.
pub fn spawnCubeField(world: *ecs.World, count: usize) !void {
    const static_count = count * 7 / 10;

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

    while (i < count) : (i += 1) {
        const fi = @as(f32, @floatFromInt(i - static_count));
        const x = @cos(fi * 1.7) * 4.0;
        const y = 5.0 + fi * 1.5;
        const z = @sin(fi * 1.3) * 4.0 - 10.0;
        _ = try spawnDynamicCube(world, x, y, z);
    }
}
