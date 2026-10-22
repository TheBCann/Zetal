//! ECS systems: the per-frame rules that run over the World, from GPU collision response to the instance build.

const std = @import("std");
const math = @import("../math.zig");
const ecs = @import("world.zig");
const physics_layout = @import("../render/physics_layout.zig");

const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const World = ecs.World;
const Entity = ecs.Entity;
const CollisionPair = physics_layout.CollisionPair;
const bit = ecs.bit;
const hasMask = ecs.hasMask;

// Component sets the systems select on, folded at comptime.
const spin_mask = ecs.mask(&.{ .transform, .spin });
const health_mask = bit(.health);
const projectile_mask = bit(.projectile);
const enemy_mask = ecs.mask(&.{ .transform, .collider, .health, .enemy_tag });
const collider_mask = ecs.mask(&.{ .transform, .collider });
const moving_mask = ecs.mask(&.{ .transform, .velocity });
const dynamic_mask = ecs.mask(&.{ .transform, .velocity, .collider });
const render_mask = ecs.mask(&.{ .transform, .mesh_renderer });

// ============================================================
// SPIN SYSTEM
// ============================================================

/// Sets every spinning entity's yaw to speed · time + offset.
pub fn spinSystem(world: *World, time_sec: f32) void {
    const n = world.count;
    for (world.masks[0..n], world.spins[0..n], world.transforms[0..n]) |m, spin, *t| {
        if (!hasMask(m, spin_mask)) continue;
        // Absolute, not accumulated: the angle never drifts with frame timing.
        t.rot_y = (spin.speed * time_sec) + spin.offset;
    }
}

// ============================================================
// HIT TIMER SYSTEM — decay the hit flash
// ============================================================

/// Hit-flash fade per second: a full 1.0 flash is gone after 0.2 s.
const HIT_FLASH_DECAY: f32 = 5.0;

/// Fades every entity's hit flash towards 0.
pub fn hitTimerSystem(world: *World, dt: f32) void {
    const n = world.count;
    for (world.masks[0..n], world.healths[0..n]) |m, *h| {
        if (!hasMask(m, health_mask)) continue;
        if (h.hit_timer > 0) {
            h.hit_timer -= dt * HIT_FLASH_DECAY;
            if (h.hit_timer < 0) h.hit_timer = 0;
        }
    }
}

// ============================================================
// HITSCAN SYSTEM — raycast damage against enemy-tagged entities
// ============================================================

// Kept as a library capability only. Primary fire is a physical projectile: hitscan never
// touches the untagged gallery blocks, so as the left-click weapon it felt like nothing happened.

/// Horizontal speed a hitscan kill throws the body at, along the shot.
const KILL_THROW_SPEED: f32 = 8.0;
/// Upward speed of a hitscan kill.
const KILL_THROW_UP: f32 = 5.0;

/// Damages the nearest enemy whose box the ray enters within max_range and returns it (null on a
/// miss). The hit flashes; a kill turns the enemy into an untargetable dynamic body thrown away
/// from the shooter. Not wired to input.
pub fn hitscanSystem(world: *World, origin: Vec3, dir: Vec3, damage: f32, max_range: f32) ?Entity {
    var closest_t = max_range;
    var hit: ?Entity = null;
    for (0..world.count) |i| {
        if (!hasMask(world.masks[i], enemy_mask)) continue;
        const box = ecs.AABB.fromTransformCollider(&world.transforms[i], &world.colliders[i]);
        const box_min: Vec3 = .init(box.min_x, box.min_y, box.min_z);
        const box_max: Vec3 = .init(box.max_x, box.max_y, box.max_z);
        const t = math.rayIntersectAABB(origin, dir, box_min, box_max) orelse continue;
        if (t < closest_t and t >= 0) {
            closest_t = t;
            hit = @as(Entity, @intCast(i));
        }
    }
    const e = hit orelse return null;

    const health = &world.healths[e];
    health.hp -= damage;
    health.hit_timer = 1.0; // hitTimerSystem fades it out
    if (health.hp <= 0) {
        health.hp = 0;
        // Ragdoll: the physics integrates it from now on, and it can't be shot again.
        world.colliders[e].is_static = false;
        world.masks[e] |= bit(.velocity);
        world.masks[e] &= ~bit(.enemy_tag);
        world.velocities[e] = .{ .x = dir.x * KILL_THROW_SPEED, .y = KILL_THROW_UP, .z = dir.z * KILL_THROW_SPEED };
    }
    return e;
}

// ============================================================
// PROJECTILE LIFETIME SYSTEM
// ============================================================

/// Ages every projectile by dt and despawns the ones whose age reached their lifetime; returns how
/// many it despawned.
pub fn projectileLifetimeSystem(world: *World, dt: f32) u32 {
    // The floor is infinite, so nothing else ever removes a shot: without this every projectile
    // stays in the physics pair list and the instance buffers forever.
    var expired: u32 = 0;
    for (0..world.count) |i| {
        if (!hasMask(world.masks[i], projectile_mask)) continue;
        const p = &world.projectiles[i];
        p.age += dt;
        if (p.age >= p.lifetime) {
            retire(world, @intCast(i));
            expired += 1;
        }
    }
    return expired;
}

// ============================================================
// GPU COLLISION RESPONSE — resolves the compute broad phase's pairs
// Impact conversion: a fast dynamic body hitting a static one
// knocks it loose (it turns dynamic and takes an impulse).
// ============================================================

/// An impactor must be strictly faster than this to knock a static body loose.
const IMPACT_SPEED_THRESHOLD: f32 = 8.0;
/// Fraction of the impactor's velocity a knocked-loose body receives.
const IMPACT_IMPULSE_SCALE: f32 = 0.6;
/// Upward pop added to a knocked-loose body.
const IMPACT_POP_Y: f32 = 3.0;
/// On a knock-loose the impactor's whole velocity is scaled by -restitution · this (-0.15 at 0.5).
const IMPACTOR_DAMPING: f32 = 0.3;

/// What one resolveCollisionPairs call knocked loose.
pub const ImpactReport = struct {
    /// Static bodies knocked loose, by any fast dynamic impactor.
    impacts: u32 = 0,
    /// The knock-looses whose impactor is a projectile: the player's confirmed hits.
    projectile_impacts: u32 = 0,
};

/// Resolves the broad phase's overlapping pairs in list order: pushes the bodies apart along the
/// axis of least penetration and reflects their velocity on it, and knocks a static body loose
/// when a dynamic one hits it faster than IMPACT_SPEED_THRESHOLD. Returns what was knocked loose.
pub fn resolveCollisionPairs(world: *World, pairs: []const CollisionPair, restitution: f32) ImpactReport {
    var report: ImpactReport = .{};
    for (pairs) |pair| {
        // A stale or corrupt pair would index past the live slots, or past the arrays.
        if (pair.a >= world.count or pair.b >= world.count) continue;
        if (pair.pen_x <= 0 or pair.pen_y <= 0 or pair.pen_z <= 0) continue;
        // The broad phase's own filter. Deliberately not velocity or is_static: a static target
        // has no velocity bit and must still be knocked loose.
        if (!hasMask(world.masks[pair.a], collider_mask) or !hasMask(world.masks[pair.b], collider_mask)) continue;

        const push = separation(world, pair);

        // Re-read for every pair: a body knocked loose earlier in the list is dynamic from then on.
        const a_static = world.colliders[pair.a].is_static;
        const b_static = world.colliders[pair.b].is_static;

        if (!a_static and !b_static) {
            // Both dynamic: split the push and reflect both on its axis (no momentum exchange).
            const half = push.scale(0.5);
            moveBy(world, pair.a, half);
            moveBy(world, pair.b, half.scale(-1));
            bounce(world, pair.a, push, restitution);
            bounce(world, pair.b, push, restitution);
        } else if (!a_static) {
            hitStatic(world, &report, pair.a, pair.b, push, restitution);
        } else if (!b_static) {
            // Mirror: `push` moves a out of b, so b leaves along its negation.
            hitStatic(world, &report, pair.b, pair.a, push.scale(-1), restitution);
        }
        // Two static bodies: nothing moves (the broad phase never emits such pairs anyway).
    }
    return report;
}

/// Returns the push that moves pair.a out of pair.b along the axis of least penetration (ties
/// pick x, then y, else z). The sign comes from the bodies' current positions: negative when a
/// lies on the lower side, positive otherwise, including a tie.
fn separation(world: *const World, pair: CollisionPair) Vec3 {
    const a = &world.transforms[pair.a];
    const b = &world.transforms[pair.b];
    if (pair.pen_x <= pair.pen_y and pair.pen_x <= pair.pen_z) {
        return .init(if (a.x < b.x) -pair.pen_x else pair.pen_x, 0, 0);
    } else if (pair.pen_y <= pair.pen_x and pair.pen_y <= pair.pen_z) {
        return .init(0, if (a.y < b.y) -pair.pen_y else pair.pen_y, 0);
    } else {
        return .init(0, 0, if (a.z < b.z) -pair.pen_z else pair.pen_z);
    }
}

/// Resolves a dynamic impactor overlapping a static target; `out` moves the impactor out of it.
/// Fast enough, the impactor knocks the target loose (recorded in report), otherwise it bounces.
fn hitStatic(world: *World, report: *ImpactReport, impactor: Entity, target: Entity, out: Vec3, restitution: f32) void {
    const v = world.velocities[impactor];
    const speed_sq = v.x * v.x + v.y * v.y + v.z * v.z;
    if (speed_sq > IMPACT_SPEED_THRESHOLD * IMPACT_SPEED_THRESHOLD) {
        // Knock loose: the target turns dynamic, joins the integrator (velocity bit) and stops
        // spinning (a spinning cube looks wrong mid-air). Its velocity is assigned, not added to:
        // a static body never had one of its own.
        world.colliders[target].is_static = false;
        world.velocities[target] = .{
            .x = v.x * IMPACT_IMPULSE_SCALE,
            .y = v.y * IMPACT_IMPULSE_SCALE + IMPACT_POP_Y,
            .z = v.z * IMPACT_IMPULSE_SCALE,
        };
        world.masks[target] |= bit(.velocity);
        world.masks[target] &= ~bit(.spin);

        // Impactor damping, for any impactor (not only projectiles): its whole velocity reverses
        // and keeps a fraction, so it drops away from the target instead of drilling on through.
        const damping = -restitution * IMPACTOR_DAMPING;
        world.velocities[impactor] = .{ .x = v.x * damping, .y = v.y * damping, .z = v.z * damping };
        moveBy(world, impactor, out);

        report.impacts += 1;
        if (hasMask(world.masks[impactor], projectile_mask)) report.projectile_impacts += 1;
    } else {
        moveBy(world, impactor, out);
        bounce(world, impactor, out, restitution);
    }
}

/// Moves e by d.
fn moveBy(world: *World, e: Entity, d: Vec3) void {
    const t = &world.transforms[e];
    t.x += d.x;
    t.y += d.y;
    t.z += d.z;
}

/// Reflects e's velocity, scaled by restitution, on the axis `push` acts along.
fn bounce(world: *World, e: Entity, push: Vec3, restitution: f32) void {
    const v = &world.velocities[e];
    if (push.x != 0) v.x *= -restitution;
    if (push.y != 0) v.y *= -restitution;
    if (push.z != 0) v.z *= -restitution;
}

// ============================================================
// FLOOR ENFORCEMENT — keep dynamic bodies above the ground
// ============================================================

/// Share of horizontal speed a body keeps per floor contact.
const FLOOR_FRICTION: f32 = 0.92;
/// Bounces slower than this stop dead, so resting bodies don't jitter.
const MIN_BOUNCE_SPEED: f32 = 0.5;

/// Lifts every dynamic body that sank below floor_y + half_y back onto the floor; one that was
/// falling bounces with restitution and friction. The floor is infinite (no x/z bound), exactly as
/// the original.
pub fn enforceFloor(world: *World, floor_y: f32, restitution: f32) void {
    for (0..world.count) |i| {
        if (!hasMask(world.masks[i], dynamic_mask)) continue;
        const c = &world.colliders[i];
        if (c.is_static) continue;

        const t = &world.transforms[i];
        const min_y = floor_y + c.half_y;
        if (t.y < min_y) {
            t.y = min_y;
            const v = &world.velocities[i];
            if (v.y < 0) {
                v.y *= -restitution;
                v.x *= FLOOR_FRICTION;
                v.z *= FLOOR_FRICTION;
                if (@abs(v.y) < MIN_BOUNCE_SPEED) v.y = 0;
            }
        }
    }
}

// ============================================================
// CLEANUP — remove bodies that fell out of the world
// ============================================================

/// Despawns every moving, non-static body below kill_y through world.despawn (so the slots are
/// recycled); returns how many.
pub fn cleanupFallen(world: *World, kill_y: f32) u32 {
    var cleaned: u32 = 0;
    for (0..world.count) |i| {
        if (!hasMask(world.masks[i], moving_mask)) continue;
        if (world.colliders[i].is_static) continue;
        if (world.transforms[i].y < kill_y) {
            retire(world, @intCast(i));
            cleaned += 1;
        }
    }
    return cleaned;
}

/// Despawns e and, as the original cleanup did, parks the dead slot's stale data out of the play
/// area until the slot is reused.
fn retire(world: *World, e: Entity) void {
    world.despawn(e);
    world.velocities[e] = .{};
    world.transforms[e].y = 9999;
}

// ============================================================
// CAMERA COLLISION
// ============================================================

/// Returns position pushed out of every collider that a box of half-size radius around it
/// overlaps, one least-penetration axis per collider.
pub fn resolveCamera(world: *const World, position: Vec3, radius: f32) Vec3 {
    // As the original, the box stays where the camera started: every penetration is measured from
    // the input position, and only the push direction looks at the corrected one.
    const cam_box: ecs.AABB = .{
        .min_x = position.x - radius,
        .min_y = position.y - radius,
        .min_z = position.z - radius,
        .max_x = position.x + radius,
        .max_y = position.y + radius,
        .max_z = position.z + radius,
    };
    var p = position;
    for (0..world.count) |i| {
        if (!hasMask(world.masks[i], collider_mask)) continue;
        const t = &world.transforms[i];
        const box = ecs.AABB.fromTransformCollider(t, &world.colliders[i]);
        if (!cam_box.overlaps(box)) continue;

        const pen = cam_box.penetration(box);
        if (pen.x <= 0 or pen.y <= 0 or pen.z <= 0) continue;
        if (pen.x <= pen.y and pen.x <= pen.z) {
            p.x = if (p.x < t.x) p.x - pen.x else p.x + pen.x;
        } else if (pen.y <= pen.x and pen.y <= pen.z) {
            p.y = if (p.y < t.y) p.y - pen.y else p.y + pen.y;
        } else {
            p.z = if (p.z < t.z) p.z - pen.z else p.z + pen.z;
        }
    }
    return p;
}

// ============================================================
// RENDER — per-instance data for the instanced cube draws
// ============================================================

/// Where buildInstances writes: normally the renderer's InstanceBuffers slices (one capacity).
pub const InstanceOutputs = struct {
    /// view_proj · model per instance.
    mvps: []Mat4,
    /// World matrix per instance; lighting needs it apart from the MVP.
    models: []Mat4,
    /// light_view_proj · model per instance, for the shadow pass.
    shadow_mvps: []Mat4,
    /// Hit-flash strength per instance; 0 for entities without Health.
    hit_timers: []f32,
};

/// Writes one instance per renderable entity (transform + mesh renderer) in slot order and returns
/// how many. Stops when the outputs are full: at most out.mvps.len, and never past the shortest
/// output slice.
pub fn buildInstances(world: *const World, view_proj: Mat4, light_view_proj: Mat4, out: InstanceOutputs) u32 {
    const capacity = @min(out.mvps.len, out.models.len, out.shadow_mvps.len, out.hit_timers.len);
    var n: u32 = 0;
    for (0..world.count) |i| {
        if (n == capacity) break;
        const m = world.masks[i];
        if (!hasMask(m, render_mask)) continue;

        const model = modelMatrix(&world.transforms[i]);
        out.models[n] = model;
        out.mvps[n] = view_proj.mul(model);
        out.shadow_mvps[n] = light_view_proj.mul(model);
        out.hit_timers[n] = if (hasMask(m, health_mask)) world.healths[i].hit_timer else 0;
        n += 1;
    }
    return n;
}

/// Returns translate · rotY · uniform scale, built in place as the original did (only the yaw is
/// rendered; rot_x and rot_z are ignored).
fn modelMatrix(t: *const ecs.Transform) Mat4 {
    var m = Mat4.rotationY(t.rot_y);
    for (m.columns[0..3]) |*column| {
        for (column[0..3]) |*v| v.* *= t.scale;
    }
    m.columns[3] = .{ t.x, t.y, t.z, 1 };
    return m;
}

// ============================================================
// TESTS
// ============================================================

const testing = std.testing;

/// A wall/target cube made like game/scene.zig spawnStaticCube: transform, mesh and a static
/// collider, but NO velocity.
fn testStaticCube(world: *World, pos: Vec3) !Entity {
    const e = try world.spawn();
    world.setTransform(e, .{ .x = pos.x, .y = pos.y, .z = pos.z });
    world.setMeshRenderer(e, .{});
    world.setCollider(e, .{ .is_static = true });
    return e;
}

/// A dynamic unit cube like spawnDynamicCube, with a starting velocity.
fn testDynamicCube(world: *World, pos: Vec3, vel: Vec3) !Entity {
    const e = try world.spawn();
    world.setTransform(e, .{ .x = pos.x, .y = pos.y, .z = pos.z });
    world.setMeshRenderer(e, .{});
    world.setVelocity(e, .{ .x = vel.x, .y = vel.y, .z = vel.z });
    world.setCollider(e, .{ .is_static = false });
    return e;
}

/// A shot like spawnProjectile: half-size dynamic cube with the Projectile component.
fn testProjectile(world: *World, pos: Vec3, vel: Vec3) !Entity {
    const e = try world.spawn();
    world.setTransform(e, .{ .x = pos.x, .y = pos.y, .z = pos.z, .scale = 0.5 });
    world.setMeshRenderer(e, .{});
    world.setVelocity(e, .{ .x = vel.x, .y = vel.y, .z = vel.z });
    world.setCollider(e, .{ .half_x = 0.25, .half_y = 0.25, .half_z = 0.25, .is_static = false });
    world.setProjectile(e, .{});
    return e;
}

/// An enemy like spawnEnemy: a static cube with Health and the enemy tag.
fn testEnemy(world: *World, pos: Vec3, hp: f32) !Entity {
    const e = try testStaticCube(world, pos);
    world.setHealth(e, .{ .hp = hp, .max_hp = hp });
    world.setEnemyTag(e);
    return e;
}

/// The pair the broad phase emits for a and b at their current positions (same penetration formula).
fn testPair(world: *const World, a: Entity, b: Entity) CollisionPair {
    const box_a = ecs.AABB.fromTransformCollider(&world.transforms[a], &world.colliders[a]);
    const box_b = ecs.AABB.fromTransformCollider(&world.transforms[b], &world.colliders[b]);
    const pen = box_a.penetration(box_b);
    return .{ .a = a, .b = b, .pen_x = pen.x, .pen_y = pen.y, .pen_z = pen.z };
}

fn positionOf(world: *const World, e: Entity) Vec3 {
    const t = world.transforms[e];
    return .init(t.x, t.y, t.z);
}

fn velocityOf(world: *const World, e: Entity) Vec3 {
    const v = world.velocities[e];
    return .init(v.x, v.y, v.z);
}

fn expectVec3(expected: Vec3, actual: Vec3, tolerance: f32) !void {
    try testing.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try testing.expectApproxEqAbs(expected.y, actual.y, tolerance);
    try testing.expectApproxEqAbs(expected.z, actual.z, tolerance);
}

fn expectPoint(expected: [4]f32, actual: [4]f32) !void {
    for (expected, actual) |e, a| try testing.expectApproxEqAbs(e, a, 1e-5);
}

test "spinSystem sets yaw from time and offset on spinning entities only" {
    var world = World.init();
    const spinner = try testStaticCube(&world, .zero);
    world.setSpin(spinner, .{ .speed = 2, .offset = 0.5 });
    world.transforms[spinner].rot_y = 9; // overwritten, never accumulated
    const still = try testStaticCube(&world, .init(3, 0, 0));
    world.transforms[still].rot_y = 0.25;

    spinSystem(&world, 1.5);
    try testing.expectApproxEqAbs(3.5, world.transforms[spinner].rot_y, 1e-6);
    try testing.expectEqual(0.25, world.transforms[still].rot_y);
}

test "hitTimerSystem fades the hit flash at 5 per second and clamps at zero" {
    var world = World.init();
    const enemy = try testEnemy(&world, .zero, 100);
    world.healths[enemy].hit_timer = 1.0;
    const plain = try testStaticCube(&world, .init(2, 0, 0));
    world.healths[plain].hit_timer = 0.75; // stale data without the Health bit

    hitTimerSystem(&world, 0.1);
    try testing.expectApproxEqAbs(0.5, world.healths[enemy].hit_timer, 1e-6);
    hitTimerSystem(&world, 0.25);
    try testing.expectEqual(0, world.healths[enemy].hit_timer);
    try testing.expectEqual(0.75, world.healths[plain].hit_timer);
}

test "hitscanSystem damages the nearest enemy on the ray and turns a kill into a dynamic body" {
    var world = World.init();
    const far = try testEnemy(&world, .init(0, 0, -10), 100);
    const near = try testEnemy(&world, .init(0, 0, -5), 30);
    _ = try testStaticCube(&world, .init(0, 0, -2)); // not an enemy: the ray passes through it
    const forward: Vec3 = .init(0, 0, -1);

    try testing.expectEqual(near, hitscanSystem(&world, .zero, forward, 25, 100));
    try testing.expectApproxEqAbs(5, world.healths[near].hp, 1e-6);
    try testing.expectEqual(1, world.healths[near].hit_timer);
    try testing.expect(world.colliders[near].is_static);
    try testing.expectEqual(100, world.healths[far].hp);

    // The second hit kills: hp clamps to 0 and the body is thrown, dynamic and untargetable.
    try testing.expectEqual(near, hitscanSystem(&world, .zero, forward, 25, 100));
    try testing.expectEqual(0, world.healths[near].hp);
    try testing.expect(!world.colliders[near].is_static);
    try testing.expect(world.has(near, .velocity));
    try testing.expect(!world.has(near, .enemy_tag));
    try expectVec3(.init(0, 5, -8), velocityOf(&world, near), 1e-6);

    // The dead enemy no longer shields the one behind it.
    try testing.expectEqual(far, hitscanSystem(&world, .zero, forward, 25, 100));
    try testing.expectApproxEqAbs(75, world.healths[far].hp, 1e-6);

    // Out of range (its front face is 9.5 away) and off-axis shots miss and hurt nobody.
    try testing.expectEqual(null, hitscanSystem(&world, .zero, forward, 25, 9));
    try testing.expectEqual(null, hitscanSystem(&world, .zero, .init(0, 1, 0), 25, 100));
    try testing.expectApproxEqAbs(75, world.healths[far].hp, 1e-6);
}

test "projectileLifetimeSystem ages shots, despawns them at their lifetime and recycles the slots" {
    var world = World.init();
    const cube = try testStaticCube(&world, .zero);
    const shot = try testProjectile(&world, .init(0, 0, -5), .init(0, 0, -40)); // default 10 s
    const short = try testProjectile(&world, .init(1, 0, -5), .init(0, 0, -40));
    world.projectiles[short].lifetime = 1.0;

    try testing.expectEqual(0, projectileLifetimeSystem(&world, 0.5));
    try testing.expectEqual(0.5, world.projectiles[shot].age);
    try testing.expectEqual(1, projectileLifetimeSystem(&world, 0.5)); // short is exactly 1 s old
    try testing.expectEqual(0, world.masks[short]);
    try testing.expect(world.has(shot, .projectile));

    try testing.expectEqual(0, projectileLifetimeSystem(&world, 8.5)); // 9.5 s
    try testing.expectEqual(1, projectileLifetimeSystem(&world, 0.5)); // 10 s
    try testing.expectEqual(0, world.masks[shot]);
    try testing.expectEqual(0, projectileLifetimeSystem(&world, 100)); // nothing left to age
    try testing.expect(world.has(cube, .collider));
    try testing.expectEqual(1, world.liveCount());

    // Both slots are recycled, last despawned first.
    try testing.expectEqual(shot, try world.spawn());
    try testing.expectEqual(short, try world.spawn());
}

test "resolveCollisionPairs: two dynamic bodies split the push and both bounce on its axis" {
    var world = World.init();
    const a = try testDynamicCube(&world, .zero, .init(2, 1, 0));
    const b = try testDynamicCube(&world, .init(0.75, 0.25, 0), .init(-3, 0, 0.5));
    // pen = (0.25, 0.75, 1): x is the shallowest axis, and a lies on its low side.
    const report = resolveCollisionPairs(&world, &.{testPair(&world, a, b)}, 0.5);

    try testing.expectEqual(ImpactReport{}, report);
    try expectVec3(.init(-0.125, 0, 0), positionOf(&world, a), 1e-6);
    try expectVec3(.init(0.875, 0.25, 0), positionOf(&world, b), 1e-6);
    // Both x components reflect × -0.5; the other axes keep their velocity (no momentum exchange).
    try expectVec3(.init(-1, 1, 0), velocityOf(&world, a), 1e-6);
    try expectVec3(.init(1.5, 0, 0.5), velocityOf(&world, b), 1e-6);
}

/// A dynamic cube sunk 0.25 into the top of a static one at the origin, the dynamic body in pair
/// slot a or b; at most threshold speed it must just bounce.
fn expectBounceOffStatic(mover_in_slot_a: bool, vel: Vec3, expected_vel: Vec3) !void {
    var world = World.init();
    const mover = try testDynamicCube(&world, .init(0, 0.75, 0), vel);
    const wall = try testStaticCube(&world, .zero);
    const pair = if (mover_in_slot_a) testPair(&world, mover, wall) else testPair(&world, wall, mover);
    const report = resolveCollisionPairs(&world, &.{pair}, 0.5);

    try testing.expectEqual(ImpactReport{}, report);
    // Out along +y (the shallowest axis); only the y component reflects.
    try expectVec3(.init(0, 1, 0), positionOf(&world, mover), 1e-6);
    try expectVec3(expected_vel, velocityOf(&world, mover), 1e-6);
    try expectVec3(.zero, positionOf(&world, wall), 1e-6);
    try testing.expect(world.colliders[wall].is_static);
    try testing.expect(!world.has(wall, .velocity));
}

test "resolveCollisionPairs: a slow body bounces off a static one from either pair slot" {
    try expectBounceOffStatic(true, .init(1, -5, 0), .init(1, 2.5, 0));
    try expectBounceOffStatic(false, .init(1, -5, 0), .init(1, 2.5, 0));
    // The threshold is strict: exactly 8 u/s still bounces.
    try expectBounceOffStatic(true, .init(0, -8, 0), .init(0, 4, 0));
    try expectBounceOffStatic(false, .init(0, -8, 0), .init(0, 4, 0));
}

test "resolveCollisionPairs: a fast projectile knocks a spawnStaticCube-style cube loose" {
    var world = World.init();
    const cube = try testStaticCube(&world, .init(0, 0, -20));
    const shot = try testProjectile(&world, .init(0, 0, -19.375), .init(2, 1, -40));
    // pen z = 0.125 is the shallowest; the cube is in slot a, so this is the mirrored branch.
    const report = resolveCollisionPairs(&world, &.{testPair(&world, cube, shot)}, 0.5);

    try testing.expectEqual(ImpactReport{ .impacts = 1, .projectile_impacts = 1 }, report);
    // Static -> dynamic: velocity bit added, no spin bit, the rest of the mask kept.
    try testing.expect(!world.colliders[cube].is_static);
    try testing.expectEqual(ecs.mask(&.{ .transform, .mesh_renderer, .collider, .velocity }), world.masks[cube]);
    try testing.expect(!world.has(cube, .spin));
    // Impulse: 0.6 of the shot's velocity plus a 3 u/s pop; the cube itself is not moved.
    try expectVec3(.init(1.2, 3.6, -24), velocityOf(&world, cube), 1e-5);
    try expectVec3(.init(0, 0, -20), positionOf(&world, cube), 1e-6);
    // Impactor damping: the shot's whole velocity × -0.15, and it is pushed out of the cube.
    try expectVec3(.init(-0.3, -0.15, 6), velocityOf(&world, shot), 1e-5);
    try expectVec3(.init(0, 0, -19.25), positionOf(&world, shot), 1e-6);
    try testing.expect(world.has(shot, .projectile));
}

test "resolveCollisionPairs: knocking a spinning cube loose stops its spin" {
    var world = World.init();
    const cube = try testStaticCube(&world, .zero);
    world.setSpin(cube, .{ .offset = 0.3 });
    const shot = try testProjectile(&world, .init(0.625, 0, 0), .init(-40, 0, 0));
    const report = resolveCollisionPairs(&world, &.{testPair(&world, cube, shot)}, 0.5);

    try testing.expectEqual(ImpactReport{ .impacts = 1, .projectile_impacts = 1 }, report);
    try testing.expect(!world.has(cube, .spin));
    try testing.expect(world.has(cube, .velocity));
    world.transforms[cube].rot_y = 0.3;
    spinSystem(&world, 10);
    try testing.expectEqual(0.3, world.transforms[cube].rot_y);
}

test "resolveCollisionPairs: a fast plain cube knocks a static one loose (an impact, not a projectile impact)" {
    var world = World.init();
    const mover = try testDynamicCube(&world, .init(-0.875, 0, 0), .init(24, 2, -1));
    const wall = try testStaticCube(&world, .zero);
    const report = resolveCollisionPairs(&world, &.{testPair(&world, mover, wall)}, 0.5);

    try testing.expectEqual(ImpactReport{ .impacts = 1, .projectile_impacts = 0 }, report);
    try testing.expect(!world.colliders[wall].is_static);
    try testing.expect(world.has(wall, .velocity));
    try expectVec3(.init(14.4, 4.2, -0.6), velocityOf(&world, wall), 1e-5);
    // Impactor damping applies to any dynamic impactor: its whole velocity × -0.15.
    try expectVec3(.init(-3.6, -0.3, 0.15), velocityOf(&world, mover), 1e-5);
    // Pushed back out along -x, 0.125 deep.
    try expectVec3(.init(-1, 0, 0), positionOf(&world, mover), 1e-6);
}

test "resolveCollisionPairs: a projectile hitting a resting loose cube only bounces" {
    var world = World.init();
    // Knocked loose earlier and now at rest: dynamic, zero velocity.
    const cube = try testDynamicCube(&world, .init(0, 0, -20), .zero);
    const shot = try testProjectile(&world, .init(0, 0, -19.375), .init(2, 1, -40));
    const report = resolveCollisionPairs(&world, &.{testPair(&world, cube, shot)}, 0.5);

    try testing.expectEqual(ImpactReport{}, report);
    // No momentum exchange: the cube stays at rest and only the shot's z component flips × -0.5.
    try expectVec3(.zero, velocityOf(&world, cube), 1e-6);
    try expectVec3(.init(2, 1, 20), velocityOf(&world, shot), 1e-6);
    // The 0.125 push is split between them.
    try expectVec3(.init(0, 0, -20.0625), positionOf(&world, cube), 1e-6);
    try expectVec3(.init(0, 0, -19.3125), positionOf(&world, shot), 1e-6);
}

test "resolveCollisionPairs: a body knocked loose earlier in the list is dynamic for later pairs" {
    var world = World.init();
    const cube = try testStaticCube(&world, .init(0, 0, -20));
    const first = try testProjectile(&world, .init(0, 0, -19.375), .init(0, 0, -40));
    const second = try testProjectile(&world, .init(0, 0.25, -19.375), .init(0, 0, -40));
    // One broad phase emits both pairs, from the positions before any resolution.
    const pairs = [_]CollisionPair{ testPair(&world, cube, first), testPair(&world, cube, second) };
    const report = resolveCollisionPairs(&world, &pairs, 0.5);

    // Only the first shot knocks the cube loose; the second meets a dynamic cube and splits the push.
    try testing.expectEqual(ImpactReport{ .impacts = 1, .projectile_impacts = 1 }, report);
    try expectVec3(.init(0, 0, -20.0625), positionOf(&world, cube), 1e-6);
    try expectVec3(.init(0, 0.25, -19.3125), positionOf(&world, second), 1e-6);
    // The cube's knock-loose velocity (0, 3, -24) then reflects on z.
    try expectVec3(.init(0, 3, 12), velocityOf(&world, cube), 1e-5);
    try expectVec3(.init(0, 0, 20), velocityOf(&world, second), 1e-6);
}

test "resolveCollisionPairs: penetration ties pick x then y, and coincident bodies push a towards +" {
    var world = World.init();
    const a = try testDynamicCube(&world, .zero, .init(1, 1, 1));
    const b = try testDynamicCube(&world, .zero, .init(1, 1, 1));

    // All three equal: x. Equal positions: `a < b` is false, so a goes +.
    _ = resolveCollisionPairs(&world, &.{.{ .a = a, .b = b, .pen_x = 0.5, .pen_y = 0.5, .pen_z = 0.5 }}, 0.5);
    try expectVec3(.init(0.25, 0, 0), positionOf(&world, a), 1e-6);
    try expectVec3(.init(-0.25, 0, 0), positionOf(&world, b), 1e-6);
    try expectVec3(.init(-0.5, 1, 1), velocityOf(&world, a), 1e-6);

    // y and z tie below x: y.
    _ = resolveCollisionPairs(&world, &.{.{ .a = a, .b = b, .pen_x = 0.75, .pen_y = 0.5, .pen_z = 0.5 }}, 0.5);
    try expectVec3(.init(0.25, 0.25, 0), positionOf(&world, a), 1e-6);
    try expectVec3(.init(-0.5, -0.5, 1), velocityOf(&world, a), 1e-6);

    // z only when it is strictly the shallowest.
    _ = resolveCollisionPairs(&world, &.{.{ .a = a, .b = b, .pen_x = 0.75, .pen_y = 0.5, .pen_z = 0.25 }}, 0.5);
    try expectVec3(.init(0.25, 0.25, 0.125), positionOf(&world, a), 1e-6);
    try expectVec3(.init(-0.25, -0.25, -0.125), positionOf(&world, b), 1e-6);
    try expectVec3(.init(-0.5, -0.5, -0.5), velocityOf(&world, a), 1e-6);
}

test "resolveCollisionPairs ignores pairs whose indices are out of range" {
    var world = World.init();
    const a = try testDynamicCube(&world, .zero, .init(1, 0, 0));
    const b = try testDynamicCube(&world, .init(0.75, 0, 0), .init(-1, 0, 0));
    const bad = [_]CollisionPair{
        .{ .a = a, .b = world.count, .pen_x = 0.25, .pen_y = 1, .pen_z = 1 }, // never handed out
        .{ .a = ecs.MAX_ENTITIES, .b = b, .pen_x = 0.25, .pen_y = 1, .pen_z = 1 }, // past the arrays
        .{ .a = std.math.maxInt(u32), .b = std.math.maxInt(u32), .pen_x = 0.25, .pen_y = 1, .pen_z = 1 },
    };
    try testing.expectEqual(ImpactReport{}, resolveCollisionPairs(&world, &bad, 0.5));
    try expectVec3(.zero, positionOf(&world, a), 1e-6);
    try expectVec3(.init(0.75, 0, 0), positionOf(&world, b), 1e-6);
    try expectVec3(.init(1, 0, 0), velocityOf(&world, a), 1e-6);

    // A valid pair behind the bad ones is still resolved, exactly once.
    const mixed = [_]CollisionPair{ bad[0], bad[1], bad[2], testPair(&world, a, b) };
    _ = resolveCollisionPairs(&world, &mixed, 0.5);
    try expectVec3(.init(-0.125, 0, 0), positionOf(&world, a), 1e-6);
    try expectVec3(.init(0.875, 0, 0), positionOf(&world, b), 1e-6);
    try expectVec3(.init(-0.5, 0, 0), velocityOf(&world, a), 1e-6);
    try expectVec3(.init(0.5, 0, 0), velocityOf(&world, b), 1e-6);
}

test "resolveCollisionPairs skips dead slots, collider-less bodies, flat penetrations and static pairs" {
    var world = World.init();
    // Fast enough that any wrongly accepted pair against a static body would knock it loose.
    const mover = try testDynamicCube(&world, .zero, .init(30, 0, 0));
    const dead = try testStaticCube(&world, .init(0.75, 0, 0));
    const ghost = try world.spawn(); // moves, but has no collider
    world.setTransform(ghost, .{ .x = 0.75 });
    world.setVelocity(ghost, .{});
    const wall = try testStaticCube(&world, .init(-0.75, 0, 0));
    const pillar = try testStaticCube(&world, .init(-0.75, 0.5, 0));
    world.despawn(dead);

    const pairs = [_]CollisionPair{
        .{ .a = mover, .b = dead, .pen_x = 0.25, .pen_y = 1, .pen_z = 1 },
        .{ .a = mover, .b = ghost, .pen_x = 0.25, .pen_y = 1, .pen_z = 1 },
        .{ .a = mover, .b = wall, .pen_x = 0, .pen_y = 1, .pen_z = 1 }, // touching only
        .{ .a = mover, .b = wall, .pen_x = 0.25, .pen_y = -0.5, .pen_z = 1 },
        testPair(&world, wall, pillar), // two static bodies
    };
    try testing.expectEqual(ImpactReport{}, resolveCollisionPairs(&world, &pairs, 0.5));
    try expectVec3(.zero, positionOf(&world, mover), 1e-6);
    try expectVec3(.init(30, 0, 0), velocityOf(&world, mover), 1e-6);
    try testing.expect(world.colliders[wall].is_static);
    try testing.expect(world.colliders[pillar].is_static);
    try expectVec3(.init(-0.75, 0.5, 0), positionOf(&world, pillar), 1e-6);
}

test "enforceFloor lifts sunk bodies onto an infinite floor, with bounce, friction and a tiny-bounce cutoff" {
    var world = World.init();
    const falling = try testDynamicCube(&world, .init(0, -11.75, 0), .init(10, -10, -5));
    const settling = try testDynamicCube(&world, .init(2, -11.625, 0), .init(1, -0.5, 0));
    const rising = try testDynamicCube(&world, .init(4, -11.75, 0), .init(2, 3, 0));
    const far_out = try testDynamicCube(&world, .init(1000, -11.75, -1000), .init(0, -4, 0));
    const shot = try testProjectile(&world, .init(6, -11.875, 0), .init(0, -20, 0));
    const pinned = try testStaticCube(&world, .init(8, -11.875, 0));
    world.setVelocity(pinned, .{ .y = -1 }); // has the velocity bit but is static
    const airborne = try testDynamicCube(&world, .init(10, 0, 0), .init(0, -5, 0));

    enforceFloor(&world, -12, 0.6);

    // Onto floor + half_y; falling into it: y × -0.6, horizontal × 0.92.
    try expectVec3(.init(0, -11.5, 0), positionOf(&world, falling), 1e-6);
    try expectVec3(.init(9.2, 6, -4.6), velocityOf(&world, falling), 1e-5);
    // A bounce under 0.5 u/s (here 0.3) is killed.
    try expectVec3(.init(2, -11.5, 0), positionOf(&world, settling), 1e-6);
    try expectVec3(.init(0.92, 0, 0), velocityOf(&world, settling), 1e-6);
    // Already moving up: lifted, but no bounce and no friction.
    try expectVec3(.init(4, -11.5, 0), positionOf(&world, rising), 1e-6);
    try expectVec3(.init(2, 3, 0), velocityOf(&world, rising), 1e-6);
    // No x/z bound: far outside the drawn ground, the floor still holds.
    try expectVec3(.init(1000, -11.5, -1000), positionOf(&world, far_out), 1e-6);
    try expectVec3(.init(0, 2.4, 0), velocityOf(&world, far_out), 1e-5);
    // A projectile's smaller collider rests lower.
    try expectVec3(.init(6, -11.75, 0), positionOf(&world, shot), 1e-6);
    try expectVec3(.init(0, 12, 0), velocityOf(&world, shot), 1e-5);
    // Static and airborne bodies are left alone.
    try expectVec3(.init(8, -11.875, 0), positionOf(&world, pinned), 1e-6);
    try expectVec3(.init(0, -1, 0), velocityOf(&world, pinned), 1e-6);
    try expectVec3(.init(10, 0, 0), positionOf(&world, airborne), 1e-6);
    try expectVec3(.init(0, -5, 0), velocityOf(&world, airborne), 1e-6);
}

test "cleanupFallen frees slots for respawning" {
    var world = World.init();
    const e = try world.spawn();
    world.setTransform(e, .{ .y = -100 });
    world.setVelocity(e, .{});
    world.setCollider(e, .{ .is_static = false });

    try testing.expectEqual(@as(u32, 1), cleanupFallen(&world, -30.0));

    // The freed slot must be available for the next spawn.
    const reused = try world.spawn();
    try testing.expectEqual(e, reused);
}

test "cleanupFallen only removes moving, non-static bodies below the kill plane" {
    var world = World.init();
    const fallen = try testDynamicCube(&world, .init(0, -31, 0), .init(0, -5, 0));
    const above = try testDynamicCube(&world, .init(0, -29, 0), .zero);
    const static_low = try testStaticCube(&world, .init(2, -40, 0));
    const pinned_low = try testStaticCube(&world, .init(4, -40, 0));
    world.setVelocity(pinned_low, .{});
    const unmoving = try world.spawn(); // non-static collider but no velocity
    world.setTransform(unmoving, .{ .y = -50 });
    world.setCollider(unmoving, .{ .is_static = false });

    try testing.expectEqual(1, cleanupFallen(&world, -30));
    try testing.expectEqual(0, world.masks[fallen]);
    try testing.expect(world.masks[above] != 0);
    try testing.expect(world.masks[static_low] != 0);
    try testing.expect(world.masks[pinned_low] != 0);
    try testing.expect(world.masks[unmoving] != 0);
    // The dead slot's leftovers are parked out of the play area.
    try expectVec3(.zero, velocityOf(&world, fallen), 1e-6);
    try testing.expectEqual(9999, world.transforms[fallen].y);
    // Already dead: not counted twice.
    try testing.expectEqual(0, cleanupFallen(&world, -30));
}

test "resolveCamera pushes the camera out of colliders along the shallowest axis" {
    var world = World.init();
    _ = try testStaticCube(&world, .zero);
    const r: f32 = 0.25;

    // Every case sits 0.125 deep in the cube's side, top/bottom or face.
    try expectVec3(.init(0.75, 0, 0), resolveCamera(&world, .init(0.625, 0, 0), r), 1e-6);
    try expectVec3(.init(0, -0.75, 0), resolveCamera(&world, .init(0, -0.625, 0), r), 1e-6);
    try expectVec3(.init(0.125, 0, -0.75), resolveCamera(&world, .init(0.125, 0, -0.625), r), 1e-6);
    try expectVec3(.init(3, 0, 0), resolveCamera(&world, .init(3, 0, 0), r), 1e-6);

    // Renderables without a collider never block; dynamic colliders, even projectiles, do.
    const decor = try world.spawn();
    world.setTransform(decor, .{ .x = 5 });
    world.setMeshRenderer(decor, .{});
    try expectVec3(.init(5, 0, 0), resolveCamera(&world, .init(5, 0, 0), r), 1e-6);
    _ = try testProjectile(&world, .init(10, 0, 0), .zero);
    try expectVec3(.init(10.5, 0, 0), resolveCamera(&world, .init(10.375, 0, 0), r), 1e-6);
}

test "buildInstances writes one T·R·S instance per renderable with its hit timer" {
    var world = World.init();
    const big = try testStaticCube(&world, .init(1, 2, 3));
    world.transforms[big].scale = 2;
    const enemy = try testEnemy(&world, .init(-4, 0, 1), 100);
    world.transforms[enemy].rot_y = std.math.pi / 2.0;
    world.healths[enemy].hit_timer = 0.75;
    const hidden = try world.spawn(); // a collider without a mesh is not drawn
    world.setTransform(hidden, .{ .x = 9 });
    world.setCollider(hidden, .{});
    const gone = try testStaticCube(&world, .init(5, 5, 5));
    world.despawn(gone);

    var mvps: [4]Mat4 = undefined;
    var models: [4]Mat4 = undefined;
    var shadow_mvps: [4]Mat4 = undefined;
    var hit_timers: [4]f32 = undefined;
    const n = buildInstances(&world, .translation(0, 0, -10), .translation(0, 10, 0), .{
        .mvps = &mvps,
        .models = &models,
        .shadow_mvps = &shadow_mvps,
        .hit_timers = &hit_timers,
    });

    try testing.expectEqual(2, n);
    // Instance 0: uniform scale 2, then the translation; MVP and shadow MVP put their matrix in front.
    try expectPoint(.{ 1, 2, 3, 1 }, models[0].transformPoint(.zero));
    try expectPoint(.{ 3, 2, 3, 1 }, models[0].transformPoint(.init(1, 0, 0)));
    try expectPoint(.{ 1, 2, -7, 1 }, mvps[0].transformPoint(.zero));
    try expectPoint(.{ 1, 12, 3, 1 }, shadow_mvps[0].transformPoint(.zero));
    try testing.expectEqual(0, hit_timers[0]); // no Health
    // Instance 1: rotY(π/2) turns +x into -z before translating.
    try expectPoint(.{ -4, 0, 0, 1 }, models[1].transformPoint(.init(1, 0, 0)));
    try expectPoint(.{ -4, 0, -9, 1 }, mvps[1].transformPoint(.zero));
    try testing.expectEqual(0.75, hit_timers[1]);
}

test "buildInstances stops when the shortest output is full" {
    var world = World.init();
    for (0..3) |i| _ = try testStaticCube(&world, .init(@floatFromInt(i), 0, 0));

    var mvps: [3]Mat4 = undefined;
    var models: [3]Mat4 = undefined;
    var shadow_mvps: [3]Mat4 = undefined;
    var hit_timers: [3]f32 = @splat(-1);
    const n = buildInstances(&world, .identity, .identity, .{
        .mvps = mvps[0..2],
        .models = &models,
        .shadow_mvps = &shadow_mvps,
        .hit_timers = &hit_timers,
    });
    try testing.expectEqual(2, n);
    try expectPoint(.{ 1, 0, 0, 1 }, models[1].transformPoint(.zero));
    try testing.expectEqual(-1, hit_timers[2]); // never written

    // A shorter slice elsewhere bounds the count too, and an empty output writes nothing.
    try testing.expectEqual(1, buildInstances(&world, .identity, .identity, .{
        .mvps = &mvps,
        .models = &models,
        .shadow_mvps = &shadow_mvps,
        .hit_timers = hit_timers[0..1],
    }));
    try testing.expectEqual(0, buildInstances(&world, .identity, .identity, .{
        .mvps = mvps[0..0],
        .models = &models,
        .shadow_mvps = &shadow_mvps,
        .hit_timers = &hit_timers,
    }));
}
