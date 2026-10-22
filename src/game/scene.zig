//! Scene construction: a spawn helper per kind of body, the shooting gallery and the legacy cube field.

const std = @import("std");
const math = @import("../math.zig");
const ecs = @import("../ecs/world.zig");

const Vec3 = math.Vec3;
const World = ecs.World;
const Entity = ecs.Entity;

// ============================================================
// SPAWN HELPERS — one per kind of body
// ============================================================

// Every collider made here has a half-extent of at most 0.5: the GPU broad phase searches a
// 3×3×3 cell neighbourhood, which only finds every pair while each half-extent stays
// ≤ CELL_SIZE / 2 (render/physics.zig).

/// Collider half-extent of a unit cube.
const CUBE_HALF_EXTENT: f32 = 0.5;
/// Render scale of a projectile: a half-size cube, with a collider to match.
const PROJECTILE_SCALE: f32 = 0.5;
/// Collider half-extent of a projectile.
const PROJECTILE_HALF_EXTENT: f32 = 0.25;
/// Every body draws as the cube mesh with the world texture.
const CUBE_MESH: ecs.MeshRenderer = .{ .mesh_id = 0, .texture_id = 0 };

/// Spawns a static unit cube (a wall or gallery block): drawn and collidable, it stays put until
/// a fast impact knocks it loose.
pub fn spawnStaticCube(world: *World, pos: Vec3) !Entity {
    const e = try world.spawn();
    world.setTransform(e, at(pos));
    world.setMeshRenderer(e, CUBE_MESH);
    world.setCollider(e, cubeCollider(CUBE_HALF_EXTENT, true));
    return e;
}

/// Spawns a static unit cube that turns about y at 1 rad/s, `spin_offset` radians ahead.
pub fn spawnSpinningCube(world: *World, pos: Vec3, spin_offset: f32) !Entity {
    const e = try spawnStaticCube(world, pos);
    world.setSpin(e, .{ .speed = 1.0, .offset = spin_offset });
    return e;
}

/// Spawns a dynamic unit cube at rest; gravity and collisions move it from the next physics step.
pub fn spawnDynamicCube(world: *World, pos: Vec3) !Entity {
    const e = try world.spawn();
    world.setTransform(e, at(pos));
    world.setMeshRenderer(e, CUBE_MESH);
    world.setVelocity(e, .{});
    world.setCollider(e, cubeCollider(CUBE_HALF_EXTENT, false));
    return e;
}

/// Spawns a fired shot: a half-size dynamic cube moving at `velocity`, which
/// projectileLifetimeSystem despawns once its Projectile lifetime runs out.
pub fn spawnProjectile(world: *World, pos: Vec3, velocity: Vec3) !Entity {
    const e = try world.spawn();
    world.setTransform(e, .{ .x = pos.x, .y = pos.y, .z = pos.z, .scale = PROJECTILE_SCALE });
    world.setMeshRenderer(e, CUBE_MESH);
    world.setVelocity(e, .{ .x = velocity.x, .y = velocity.y, .z = velocity.z });
    world.setCollider(e, cubeCollider(PROJECTILE_HALF_EXTENT, false));
    // The floor is infinite, so nothing else would ever remove a shot from the world.
    world.setProjectile(e, .{});
    return e;
}

/// Spawns a static enemy cube with `hp` hit points; the enemy tag makes it a hitscan target.
pub fn spawnEnemy(world: *World, pos: Vec3, hp: f32) !Entity {
    const e = try spawnStaticCube(world, pos);
    world.setHealth(e, .{ .hp = hp, .max_hp = hp });
    world.setEnemyTag(e);
    return e;
}

/// An unrotated, unscaled transform at `pos`.
fn at(pos: Vec3) ecs.Transform {
    return .{ .x = pos.x, .y = pos.y, .z = pos.z };
}

/// A cube-shaped collider with the given half-extent on every axis.
fn cubeCollider(half_extent: f32, is_static: bool) ecs.Collider {
    return .{ .half_x = half_extent, .half_y = half_extent, .half_z = half_extent, .is_static = is_static };
}

// ============================================================
// SCENES
// ============================================================

/// Centre-to-centre distance of neighbouring gallery cubes: a unit cube plus a 0.1 gap.
const GALLERY_SPACING: f32 = 1.1;
/// Centre height of the bottom gallery row. Its bottom faces sit at y = -10, two units above the
/// ground (-12): the original's eye-level gallery, kept as it was.
const GALLERY_BOTTOM_Y: f32 = -9.5;

/// One gallery enemy: where it floats and how many hit points it has.
const GalleryEnemy = struct { pos: Vec3, hp: f32 };

/// The elevated enemies, in the original's spawn order.
const GALLERY_ENEMIES = [_]GalleryEnemy{
    .{ .pos = .init(-4, -6, -18), .hp = 100 },
    .{ .pos = .init(3, -5, -14), .hp = 100 },
    .{ .pos = .init(-2, -4, -10), .hp = 50 },
    .{ .pos = .init(6, -7, -22), .hp = 150 },
};

/// Builds the shooting gallery: static target cubes in a 5×5 back wall, two 4×3 side walls, an
/// 8-high tower and a 4-3-2-1 pyramid, then the 4 enemies (71 renderables in all), at exactly the
/// original spawnFPSScene's positions and in its spawn order.
pub fn spawnShootingGallery(world: *World) !void {
    // Back wall: 5 rows of 5 at z = -20, centred on x = 0.
    for (0..5) |row| {
        for (0..5) |col| {
            const x = (@as(f32, @floatFromInt(col)) - 2) * GALLERY_SPACING;
            _ = try spawnStaticCube(world, .init(x, rowY(row), -20));
        }
    }
    // Side walls: 4 rows of 3 running back from z = -15; the left one (x = -8) first.
    for ([_]f32{ -8, 8 }) |x| {
        for (0..4) |row| {
            for (0..3) |col| {
                const z = @as(f32, @floatFromInt(col)) * GALLERY_SPACING - 15;
                _ = try spawnStaticCube(world, .init(x, rowY(row), z));
            }
        }
    }
    // Tower: one stack of 8 at x = 0, z = -12.
    for (0..8) |row| _ = try spawnStaticCube(world, .init(0, rowY(row), -12));
    // Pyramid: rows of 4, 3, 2 and 1 at z = -16, each centred on x = 5 by a half-spacing shift.
    for (0..4) |level| {
        const width = 4 - level;
        for (0..width) |c| {
            const x = @as(f32, @floatFromInt(c)) * GALLERY_SPACING -
                @as(f32, @floatFromInt(width - 1)) * (GALLERY_SPACING / 2) + 5;
            _ = try spawnStaticCube(world, .init(x, rowY(level), -16));
        }
    }
    for (GALLERY_ENEMIES) |enemy| _ = try spawnEnemy(world, enemy.pos, enemy.hp);
}

/// The centre height of gallery row `row` (0 = bottom).
fn rowY(row: usize) f32 {
    return @as(f32, @floatFromInt(row)) * GALLERY_SPACING + GALLERY_BOTTOM_Y;
}

/// The legacy demo scene: `count` cubes, 70% of them (rounded down) spinning static cubes on a
/// rising spiral around x = 0, z = -10, the rest dynamic cubes dropped from y = 5 upwards, with the
/// original's formulas.
pub fn spawnCubeField(world: *World, count: usize) !void {
    const static_count = count * 7 / 10;
    for (0..static_count) |i| {
        const fi: f32 = @floatFromInt(i);
        const angle = fi * 0.5;
        const radius = 2.0 + (fi * 0.1);
        const pos: Vec3 = .init(@cos(angle) * radius, (fi * 0.2) - 10.0, @sin(angle) * radius - 10.0);
        _ = try spawnSpinningCube(world, pos, fi * 0.05);
    }
    for (0..count - static_count) |i| {
        const fi: f32 = @floatFromInt(i);
        _ = try spawnDynamicCube(world, .init(@cos(fi * 1.7) * 4.0, 5.0 + fi * 1.5, @sin(fi * 1.3) * 4.0 - 10.0));
    }
}

// ============================================================
// TESTS
// ============================================================

const testing = std.testing;
const systems = @import("../ecs/systems.zig");
const CollisionPair = @import("../render/physics_layout.zig").CollisionPair;
const bit = ecs.bit;
const mask = ecs.mask;

fn positionOf(world: *const World, e: Entity) Vec3 {
    const t = world.transforms[e];
    return .init(t.x, t.y, t.z);
}

fn expectVec3(expected: Vec3, actual: Vec3, tolerance: f32) !void {
    try testing.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try testing.expectApproxEqAbs(expected.y, actual.y, tolerance);
    try testing.expectApproxEqAbs(expected.z, actual.z, tolerance);
}

/// The original spawnFPSScene's 67 cube positions (enemies excluded), computed with its exact
/// expressions (i32 counters, the same operation order) and in its spawn order.
fn originalGalleryCubes() [67]Vec3 {
    var cubes: [67]Vec3 = undefined;
    var n: usize = 0;
    var row: i32 = 0;
    while (row < 5) : (row += 1) {
        var col: i32 = 0;
        while (col < 5) : (col += 1) {
            const x = @as(f32, @floatFromInt(col - 2)) * 1.1;
            const y = @as(f32, @floatFromInt(row)) * 1.1 - 9.5;
            cubes[n] = .init(x, y, -20.0);
            n += 1;
        }
    }
    for ([_]f32{ -8.0, 8.0 }) |x| {
        row = 0;
        while (row < 4) : (row += 1) {
            var col: i32 = 0;
            while (col < 3) : (col += 1) {
                const z = @as(f32, @floatFromInt(col)) * 1.1 - 15.0;
                const y = @as(f32, @floatFromInt(row)) * 1.1 - 9.5;
                cubes[n] = .init(x, y, z);
                n += 1;
            }
        }
    }
    row = 0;
    while (row < 8) : (row += 1) {
        const y = @as(f32, @floatFromInt(row)) * 1.1 - 9.5;
        cubes[n] = .init(0.0, y, -12.0);
        n += 1;
    }
    var level: i32 = 0;
    while (level < 4) : (level += 1) {
        const width = 4 - level;
        var c: i32 = 0;
        while (c < width) : (c += 1) {
            const x = @as(f32, @floatFromInt(c)) * 1.1 - @as(f32, @floatFromInt(width - 1)) * 0.55 + 5.0;
            const y = @as(f32, @floatFromInt(level)) * 1.1 - 9.5;
            cubes[n] = .init(x, y, -16.0);
            n += 1;
        }
    }
    std.debug.assert(n == cubes.len);
    return cubes;
}

test "each spawn helper builds the component set the systems select on" {
    var world = World.init();

    const block = try spawnStaticCube(&world, .init(1, 2, 3));
    try testing.expectEqual(mask(&.{ .transform, .mesh_renderer, .collider }), world.masks[block]);
    try testing.expectEqual(ecs.Transform{ .x = 1, .y = 2, .z = 3 }, world.transforms[block]);
    const unit_static: ecs.Collider = .{ .half_x = 0.5, .half_y = 0.5, .half_z = 0.5, .is_static = true };
    try testing.expectEqual(unit_static, world.colliders[block]);

    const spinner = try spawnSpinningCube(&world, .init(-1, 0, 0), 0.75);
    try testing.expectEqual(mask(&.{ .transform, .spin, .mesh_renderer, .collider }), world.masks[spinner]);
    try testing.expectEqual(ecs.Spin{ .speed = 1, .offset = 0.75 }, world.spins[spinner]);
    try testing.expect(world.colliders[spinner].is_static);

    const crate = try spawnDynamicCube(&world, .init(0, 5, 0));
    try testing.expectEqual(mask(&.{ .transform, .mesh_renderer, .velocity, .collider }), world.masks[crate]);
    try testing.expectEqual(ecs.Velocity{}, world.velocities[crate]);
    try testing.expectEqual(ecs.Collider{ .is_static = false }, world.colliders[crate]);

    const shot = try spawnProjectile(&world, .init(0, 1, 2), .init(3, 0, -40));
    const shot_mask = mask(&.{ .transform, .mesh_renderer, .velocity, .collider, .projectile });
    try testing.expectEqual(shot_mask, world.masks[shot]);
    try testing.expectEqual(ecs.Transform{ .x = 0, .y = 1, .z = 2, .scale = 0.5 }, world.transforms[shot]);
    try testing.expectEqual(ecs.Velocity{ .x = 3, .z = -40 }, world.velocities[shot]);
    const half_dynamic: ecs.Collider = .{ .half_x = 0.25, .half_y = 0.25, .half_z = 0.25, .is_static = false };
    try testing.expectEqual(half_dynamic, world.colliders[shot]);
    try testing.expectEqual(ecs.Projectile{ .age = 0, .lifetime = 10 }, world.projectiles[shot]);

    const enemy = try spawnEnemy(&world, .init(-4, -6, -18), 50);
    try testing.expectEqual(mask(&.{ .transform, .mesh_renderer, .collider, .health, .enemy_tag }), world.masks[enemy]);
    try testing.expectEqual(ecs.Health{ .hp = 50, .max_hp = 50, .hit_timer = 0 }, world.healths[enemy]);
    try testing.expect(world.colliders[enemy].is_static);

    try testing.expectEqual(5, world.liveCount());
}

test "spawn helpers fail with MaxEntitiesReached on a full world and leave it untouched" {
    var world = World.init();
    for (0..ecs.MAX_ENTITIES) |_| {
        const e = try world.spawn();
        world.setTransform(e, .{});
    }
    const masks_before = world.masks;

    try testing.expectError(error.MaxEntitiesReached, spawnStaticCube(&world, .zero));
    try testing.expectError(error.MaxEntitiesReached, spawnSpinningCube(&world, .zero, 0));
    try testing.expectError(error.MaxEntitiesReached, spawnDynamicCube(&world, .zero));
    try testing.expectError(error.MaxEntitiesReached, spawnProjectile(&world, .zero, .zero));
    try testing.expectError(error.MaxEntitiesReached, spawnEnemy(&world, .zero, 100));
    try testing.expectError(error.MaxEntitiesReached, spawnShootingGallery(&world));
    try testing.expectError(error.MaxEntitiesReached, spawnCubeField(&world, 10));

    try testing.expectEqualSlices(ecs.ComponentMask, &masks_before, &world.masks);
    try testing.expectEqual(ecs.MAX_ENTITIES, world.liveCount());
}

test "the shooting gallery is 71 static renderables, 4 of them enemies" {
    var world = World.init();
    try spawnShootingGallery(&world);

    try testing.expectEqual(71, world.liveCount());
    try testing.expectEqual(71, world.countMatching(mask(&.{ .transform, .mesh_renderer, .collider })));
    try testing.expectEqual(4, world.countMatching(mask(&.{ .health, .enemy_tag })));
    // Nothing moves or spins until a shot knocks it loose.
    try testing.expectEqual(0, world.countMatching(bit(.velocity)));
    try testing.expectEqual(0, world.countMatching(bit(.spin)));
    try testing.expectEqual(0, world.countMatching(bit(.projectile)));
    for (world.colliders[0..world.count]) |c| try testing.expect(c.is_static);

    // The enemies come last, with the original's positions and hit points.
    const enemies = [_]struct { pos: Vec3, hp: f32 }{
        .{ .pos = .init(-4, -6, -18), .hp = 100 },
        .{ .pos = .init(3, -5, -14), .hp = 100 },
        .{ .pos = .init(-2, -4, -10), .hp = 50 },
        .{ .pos = .init(6, -7, -22), .hp = 150 },
    };
    for (enemies, 67..) |expected, i| {
        const e: Entity = @intCast(i);
        try testing.expect(world.has(e, .enemy_tag));
        try testing.expectEqual(expected.pos, positionOf(&world, e));
        try testing.expectEqual(expected.hp, world.healths[e].hp);
        try testing.expectEqual(expected.hp, world.healths[e].max_hp);
    }
}

test "gallery cube positions are bit-identical to the original spawnFPSScene, in its spawn order" {
    var world = World.init();
    try spawnShootingGallery(&world);

    for (originalGalleryCubes(), 0..) |expected, i| {
        const e: Entity = @intCast(i);
        try testing.expectEqual(expected, positionOf(&world, e));
        try testing.expect(!world.has(e, .enemy_tag));
    }
    // The same layout in plain numbers: back wall corners, both side walls' ends, the tower top
    // and the pyramid's base and apex.
    try expectVec3(.init(-2.2, -9.5, -20), positionOf(&world, 0), 1e-5);
    try expectVec3(.init(2.2, -5.1, -20), positionOf(&world, 24), 1e-5);
    try expectVec3(.init(-8, -9.5, -15), positionOf(&world, 25), 1e-5);
    try expectVec3(.init(8, -6.2, -12.8), positionOf(&world, 48), 1e-5);
    try expectVec3(.init(0, -1.8, -12), positionOf(&world, 56), 1e-5);
    try expectVec3(.init(3.35, -9.5, -16), positionOf(&world, 57), 1e-5);
    try expectVec3(.init(5, -6.2, -16), positionOf(&world, 66), 1e-5);
}

test "the gallery floats two units above the ground and none of its boxes touch" {
    var world = World.init();
    try spawnShootingGallery(&world);

    var lowest = std.math.inf(f32);
    for (0..world.count) |i| {
        const box = ecs.AABB.fromTransformCollider(&world.transforms[i], &world.colliders[i]);
        lowest = @min(lowest, box.min_y);
        for (i + 1..world.count) |j| {
            const other = ecs.AABB.fromTransformCollider(&world.transforms[j], &world.colliders[j]);
            try testing.expect(!box.overlaps(other));
        }
    }
    // Bottom faces at y = -10 over the ground plane at -12 (the original's layout).
    try testing.expectApproxEqAbs(@as(f32, -10), lowest, 1e-5);
}

test "a spawnProjectile shot knocks a spawnStaticCube block loose as a projectile impact" {
    var world = World.init();
    const block = try spawnStaticCube(&world, .init(0, -9.5, -20));
    // 0.125 into the block's front face, flying at the 40 u/s muzzle speed.
    const shot = try spawnProjectile(&world, .init(0, -9.5, -19.375), .init(0, 0, -40));
    const box_block = ecs.AABB.fromTransformCollider(&world.transforms[block], &world.colliders[block]);
    const box_shot = ecs.AABB.fromTransformCollider(&world.transforms[shot], &world.colliders[shot]);
    const pen = box_block.penetration(box_shot);
    const pair: CollisionPair = .{ .a = block, .b = shot, .pen_x = pen.x, .pen_y = pen.y, .pen_z = pen.z };

    const report = systems.resolveCollisionPairs(&world, &.{pair}, 0.5);

    try testing.expectEqual(systems.ImpactReport{ .impacts = 1, .projectile_impacts = 1 }, report);
    try testing.expect(!world.colliders[block].is_static);
    try testing.expect(world.has(block, .velocity));
    // 0.6 of the shot's velocity plus the 3 u/s upward pop.
    const v = world.velocities[block];
    try expectVec3(.init(0, 3, -24), .init(v.x, v.y, v.z), 1e-5);
}

test "spawnCubeField keeps the original's spiral-and-drop formulas and 70/30 split" {
    var world = World.init();
    try spawnCubeField(&world, 10);

    try testing.expectEqual(10, world.liveCount());
    try testing.expectEqual(7, world.countMatching(mask(&.{ .transform, .spin, .mesh_renderer, .collider })));
    try testing.expectEqual(3, world.countMatching(mask(&.{ .transform, .velocity, .mesh_renderer, .collider })));
    for (world.colliders[0..7]) |c| try testing.expect(c.is_static);
    for (world.colliders[7..10]) |c| try testing.expect(!c.is_static);

    // Spiral: angle 0.5 and radius +0.1 per cube, rising 0.2, each spin 0.05 rad further on.
    try expectVec3(.init(2, -10, -10), positionOf(&world, 0), 1e-6);
    try testing.expectEqual(0, world.spins[0].offset);
    const a: f32 = 0.5;
    try expectVec3(.init(@cos(a) * 2.1, -9.8, @sin(a) * 2.1 - 10), positionOf(&world, 1), 1e-5);
    try testing.expectApproxEqAbs(0.05, world.spins[1].offset, 1e-6);
    try testing.expectEqual(1, world.spins[1].speed);
    // Drop: the first at (4, 5, -10), then 1.5 higher each, wandering in x and z.
    try expectVec3(.init(4, 5, -10), positionOf(&world, 7), 1e-6);
    const f: f32 = 1;
    try expectVec3(.init(@cos(f * 1.7) * 4, 6.5, @sin(f * 1.3) * 4 - 10), positionOf(&world, 8), 1e-5);
    try testing.expectEqual(ecs.Velocity{}, world.velocities[9]);
}

test "spawnCubeField rounds the static share down and spawns nothing for zero" {
    var world = World.init();
    try spawnCubeField(&world, 0);
    try testing.expectEqual(0, world.liveCount());

    try spawnCubeField(&world, 3); // 3 · 7 / 10 = 2 static
    try testing.expectEqual(2, world.countMatching(bit(.spin)));
    try testing.expectEqual(1, world.countMatching(bit(.velocity)));
}
