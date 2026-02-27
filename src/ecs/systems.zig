const std = @import("std");
const ecs = @import("world.zig");
const math = @import("../render/root.zig").math;
const compute = @import("../render/compute.zig");

// ============================================================
// HITSCAN SYSTEM — Raycast from camera, damage nearest enemy
// ============================================================

const enemy_mask = ecs.mask(&.{ .transform, .collider, .health, .enemy_tag });

/// Fire a hitscan ray. Returns the entity ID of the hit enemy, or null.
/// Applies `damage` to the nearest enemy along the ray within `max_range
pub fn hitscanSystem(
    world: *ecs.World,
    origin: math.Vec3,
    dir: math.Vec3,
    damamge: f32,
    max_range: f32,
) ?ecs.Entity {
    var closest_t: f32 = max_range;
    var hit_entity: ?ecs.Entity = null;

    for (0..world.count) |i| {
        if (!ecs.hasMask(world.masks[i], enemy_mask)) continue;

        const t = &world.transforms[i];
        const c = &world.colliders[i];

        const box_min = math.Vec3.init(t.x - c.half_x, t.y - c.half_y, t.z - c.half_z);
        const box_max = math.Vec3.init(t.x + c.half_x, t.y + c.half_y, t.z + c.half_z);

        if (math.rayIntersectAABB(origin, dir, box_min, box_max)) |dist| {
            if (dist < closest_t and dist >= 0) {
                closest_t = dist;
                hit_entity = @intCast(i);
            }
        }
    }

    if (hit_entity) |e| {
        const hp = &world.healths[e];
        hp.hp -= damamge;
        hp.hit_timer = 1.0; // Flash for ~0.2s (decayed by hitTimerSystem)

        // enemy killed - convert to dynamic ragdoll
        if (hp.hp <= 0) {
            hp.hp = 0;

            // Give it velocity so it tumbles
            world.colliders[0].is_static = false;
            world.masks[e] |= ecs.mask(&.{.velocity});
            world.masks[e] &= ~ecs.mask(&.{.enemy_tag}); // No longer targetable

            // Push away from shooter
            world.velocities[e] = .{
                .x = dir.x * 8.0,
                .y = 5.0,
                .z = dir.z * 8.0,
            };
        }
    }

    return hit_entity;
}

// ============================================================
// HIT TIMER SYSTEM — Decay hit flash timers
// ============================================================

const health_mask = ecs.mask(&.{.health});

pub fn hitTimerSystem(world: *ecs.World, dt: f32) void {
    for (0..world.count) |i| {
        if (!ecs.hasMask(world.masks[i], health_mask)) continue;

        if (world.healths[i].hit_timer > 0) {
            world.healths[i].hit_timer -= dt * 5.0; // ~0.2s flash
            if (world.healths[i].hit_timer < 0) world.healths[i].hit_timer = 0;
        }
    }
}

// ============================================================
// SPIN SYSTEM
// ============================================================

const spin_mask = ecs.mask(&.{ .transform, .spin });

pub fn spinSystem(world: *ecs.World, time_sec: f32) void {
    for (0..world.count) |i| {
        if (!ecs.hasMask(world.masks[i], spin_mask)) continue;

        const spin = &world.spins[i];
        const transform = &world.transforms[i];
        transform.rot_y = (spin.speed * time_sec) + spin.offset;
    }
}

// ============================================================
// VELOCITY SYSTEM (CPU fallback — GPU compute replaces this)
// ============================================================

const velocity_mask = ecs.mask(&.{ .transform, .velocity });

pub fn velocitySystem(world: *ecs.World, dt: f32) void {
    for (0..world.count) |i| {
        if (!ecs.hasMask(world.masks[i], velocity_mask)) continue;

        const vel = &world.velocities[i];
        const transform = &world.transforms[i];
        transform.x += vel.x * dt;
        transform.y += vel.y * dt;
        transform.z += vel.z * dt;
    }
}

// ============================================================
// COLLISION SYSTEM (CPU fallback — GPU broad phase replaces this)
// ============================================================

const collider_mask = ecs.mask(&.{ .transform, .collider });

pub fn collisionSystem(world: *ecs.World) void {
    var i: u32 = 0;
    while (i < world.count) : (i += 1) {
        if (!ecs.hasMask(world.masks[i], collider_mask)) continue;

        var j: u32 = i + 1;
        while (j < world.count) : (j += 1) {
            if (!ecs.hasMask(world.masks[j], collider_mask)) continue;

            const a_box = ecs.AABB.fromTransformCollider(&world.transforms[i], &world.colliders[i]);
            const b_box = ecs.AABB.fromTransformCollider(&world.transforms[j], &world.colliders[j]);

            if (!a_box.overlaps(b_box)) continue;
            if (world.colliders[i].is_static and world.colliders[j].is_static) continue;

            const pen = a_box.penetration(b_box);
            if (pen.x <= 0 or pen.y <= 0 or pen.z <= 0) continue;

            const abs_x = pen.x;
            const abs_y = pen.y;
            const abs_z = pen.z;

            var push_x: f32 = 0;
            var push_y: f32 = 0;
            var push_z: f32 = 0;

            if (abs_x <= abs_y and abs_x <= abs_z) {
                if (world.transforms[i].x < world.transforms[j].x) {
                    push_x = -abs_x;
                } else {
                    push_x = abs_x;
                }
            } else if (abs_y <= abs_x and abs_y <= abs_z) {
                if (world.transforms[i].y < world.transforms[j].y) {
                    push_y = -abs_y;
                } else {
                    push_y = abs_y;
                }
            } else {
                if (world.transforms[i].z < world.transforms[j].z) {
                    push_z = -abs_z;
                } else {
                    push_z = abs_z;
                }
            }

            const a_static = world.colliders[i].is_static;
            const b_static = world.colliders[j].is_static;

            if (!a_static and !b_static) {
                world.transforms[i].x += push_x * 0.5;
                world.transforms[i].y += push_y * 0.5;
                world.transforms[i].z += push_z * 0.5;
                world.transforms[j].x -= push_x * 0.5;
                world.transforms[j].y -= push_y * 0.5;
                world.transforms[j].z -= push_z * 0.5;
            } else if (!a_static) {
                world.transforms[i].x += push_x;
                world.transforms[i].y += push_y;
                world.transforms[i].z += push_z;
            } else {
                world.transforms[j].x -= push_x;
                world.transforms[j].y -= push_y;
                world.transforms[j].z -= push_z;
            }
        }
    }
}

// ============================================================
// GPU COLLISION RESPONSE — Resolves pairs from compute broad phase
// Now with IMPACT CONVERSION: fast dynamic hitting static → static
// becomes dynamic and receives impulse (knockdown physics).
// ============================================================

const IMPACT_SPEED_THRESHOLD: f32 = 8.0; // Min speed to knock a static cube loose
const IMPACT_IMPULSE_SCALE: f32 = 0.6; // How much of projectile velocity transfers

pub fn resolveCollisionPairs(
    world: *ecs.World,
    pairs: []const compute.CollisionPair,
    restitution: f32,
) void {
    for (pairs) |pair| {
        const i: usize = pair.a;
        const j: usize = pair.b;

        if (pair.pen_x <= 0 or pair.pen_y <= 0 or pair.pen_z <= 0) continue;

        // Find minimum penetration axis
        var push_x: f32 = 0;
        var push_y: f32 = 0;
        var push_z: f32 = 0;

        if (pair.pen_x <= pair.pen_y and pair.pen_x <= pair.pen_z) {
            push_x = if (world.transforms[i].x < world.transforms[j].x) -pair.pen_x else pair.pen_x;
        } else if (pair.pen_y <= pair.pen_x and pair.pen_y <= pair.pen_z) {
            push_y = if (world.transforms[i].y < world.transforms[j].y) -pair.pen_y else pair.pen_y;
        } else {
            push_z = if (world.transforms[i].z < world.transforms[j].z) -pair.pen_z else pair.pen_z;
        }

        const a_static = world.colliders[i].is_static;
        const b_static = world.colliders[j].is_static;

        if (!a_static and !b_static) {
            // Both dynamic: split push equally
            world.transforms[i].x += push_x * 0.5;
            world.transforms[i].y += push_y * 0.5;
            world.transforms[i].z += push_z * 0.5;
            world.transforms[j].x -= push_x * 0.5;
            world.transforms[j].y -= push_y * 0.5;
            world.transforms[j].z -= push_z * 0.5;

            // Bounce: reflect velocity on collision axis
            if (push_x != 0) {
                world.velocities[i].x *= -restitution;
                world.velocities[j].x *= -restitution;
            }
            if (push_y != 0) {
                world.velocities[i].y *= -restitution;
                world.velocities[j].y *= -restitution;
            }
            if (push_z != 0) {
                world.velocities[i].z *= -restitution;
                world.velocities[j].z *= -restitution;
            }
        } else if (!a_static and b_static) {
            // A is dynamic, B is static
            // Check if A is fast enough to knock B loose
            const speed_sq = world.velocities[i].x * world.velocities[i].x +
                world.velocities[i].y * world.velocities[i].y +
                world.velocities[i].z * world.velocities[i].z;

            if (speed_sq > IMPACT_SPEED_THRESHOLD * IMPACT_SPEED_THRESHOLD) {
                // === IMPACT: Convert B from static to dynamic ===
                world.colliders[j].is_static = false;

                // Transfer momentum: B gets fraction of A's velocity
                world.velocities[j].x = world.velocities[i].x * IMPACT_IMPULSE_SCALE;
                world.velocities[j].y = world.velocities[i].y * IMPACT_IMPULSE_SCALE + 3.0; // Pop upward
                world.velocities[j].z = world.velocities[i].z * IMPACT_IMPULSE_SCALE;

                // Add velocity mask to B so physics picks it up
                world.masks[j] |= ecs.mask(&.{.velocity});

                // Remove spin from the now-dynamic cube (looks weird spinning mid-air)
                world.masks[j] &= ~ecs.mask(&.{.spin});

                // Dampen projectile
                world.velocities[i].x *= -restitution * 0.3;
                world.velocities[i].y *= -restitution * 0.3;
                world.velocities[i].z *= -restitution * 0.3;

                // Push A out of B
                world.transforms[i].x += push_x;
                world.transforms[i].y += push_y;
                world.transforms[i].z += push_z;
            } else {
                // Normal bounce off static
                world.transforms[i].x += push_x;
                world.transforms[i].y += push_y;
                world.transforms[i].z += push_z;

                if (push_x != 0) world.velocities[i].x *= -restitution;
                if (push_y != 0) world.velocities[i].y *= -restitution;
                if (push_z != 0) world.velocities[i].z *= -restitution;
            }
        } else if (a_static and !b_static) {
            // A is static, B is dynamic — mirror of above
            const speed_sq = world.velocities[j].x * world.velocities[j].x +
                world.velocities[j].y * world.velocities[j].y +
                world.velocities[j].z * world.velocities[j].z;

            if (speed_sq > IMPACT_SPEED_THRESHOLD * IMPACT_SPEED_THRESHOLD) {
                // === IMPACT: Convert A from static to dynamic ===
                world.colliders[i].is_static = false;

                world.velocities[i].x = world.velocities[j].x * IMPACT_IMPULSE_SCALE;
                world.velocities[i].y = world.velocities[j].y * IMPACT_IMPULSE_SCALE + 3.0;
                world.velocities[i].z = world.velocities[j].z * IMPACT_IMPULSE_SCALE;

                world.masks[i] |= ecs.mask(&.{.velocity});
                world.masks[i] &= ~ecs.mask(&.{.spin});

                world.velocities[j].x *= -restitution * 0.3;
                world.velocities[j].y *= -restitution * 0.3;
                world.velocities[j].z *= -restitution * 0.3;

                world.transforms[j].x -= push_x;
                world.transforms[j].y -= push_y;
                world.transforms[j].z -= push_z;
            } else {
                world.transforms[j].x -= push_x;
                world.transforms[j].y -= push_y;
                world.transforms[j].z -= push_z;

                if (push_x != 0) world.velocities[j].x *= -restitution;
                if (push_y != 0) world.velocities[j].y *= -restitution;
                if (push_z != 0) world.velocities[j].z *= -restitution;
            }
        }
    }
}

// ============================================================
// FLOOR ENFORCEMENT — Clamp dynamic entities above the ground
// ============================================================

const dynamic_mask = ecs.mask(&.{ .transform, .velocity, .collider });

pub fn enforceFloor(world: *ecs.World, floor_y: f32, restitution: f32) void {
    for (0..world.count) |i| {
        if (!ecs.hasMask(world.masks[i], dynamic_mask)) continue;
        if (world.colliders[i].is_static) continue;

        const min_y = floor_y + world.colliders[i].half_y;
        if (world.transforms[i].y < min_y) {
            world.transforms[i].y = min_y;

            if (world.velocities[i].y < 0) {
                world.velocities[i].y *= -restitution;

                // Friction: dampen horizontal velocity on ground contact
                world.velocities[i].x *= 0.92;
                world.velocities[i].z *= 0.92;

                // Kill tiny bounces (prevents jitter)
                if (@abs(world.velocities[i].y) < 0.5) {
                    world.velocities[i].y = 0;
                }
            }
        }
    }
}

// ============================================================
// CLEANUP SYSTEM — Remove entities that fall below the world
// ============================================================

/// Despawn entities that fall too far below the ground.
/// Zeroes their masks so they become invisible + non-interactive.
/// Returns how many entities were cleaned up.
pub fn cleanupFallen(world: *ecs.World, kill_y: f32) u32 {
    var cleaned: u32 = 0;
    for (0..world.count) |i| {
        if (world.masks[i] == 0) continue; // Already dead
        if (!ecs.hasMask(world.masks[i], velocity_mask)) continue;
        if (world.colliders[i].is_static) continue;

        if (world.transforms[i].y < kill_y) {
            // Zero the mask — entity becomes a ghost (no render, no physics)
            world.masks[i] = 0;
            world.velocities[i] = .{ .x = 0, .y = 0, .z = 0 };
            world.transforms[i].y = 9999; // Move far away
            cleaned += 1;
        }
    }
    return cleaned;
}

// ============================================================
// CAMERA COLLISION
// ============================================================

pub fn resolveCamera(
    world: *ecs.World,
    cam_x: f32,
    cam_y: f32,
    cam_z: f32,
    cam_radius: f32,
) struct { x: f32, y: f32, z: f32 } {
    var rx = cam_x;
    var ry = cam_y;
    var rz = cam_z;

    const cam_box = ecs.AABB{
        .min_x = rx - cam_radius,
        .min_y = ry - cam_radius,
        .min_z = rz - cam_radius,
        .max_x = rx + cam_radius,
        .max_y = ry + cam_radius,
        .max_z = rz + cam_radius,
    };

    for (0..world.count) |i| {
        if (!ecs.hasMask(world.masks[i], collider_mask)) continue;

        const ent_box = ecs.AABB.fromTransformCollider(&world.transforms[i], &world.colliders[i]);

        if (!cam_box.overlaps(ent_box)) continue;

        const pen = cam_box.penetration(ent_box);
        if (pen.x <= 0 or pen.y <= 0 or pen.z <= 0) continue;

        if (pen.x <= pen.y and pen.x <= pen.z) {
            if (rx < world.transforms[i].x) {
                rx -= pen.x;
            } else {
                rx += pen.x;
            }
        } else if (pen.y <= pen.x and pen.y <= pen.z) {
            if (ry < world.transforms[i].y) {
                ry -= pen.y;
            } else {
                ry += pen.y;
            }
        } else {
            if (rz < world.transforms[i].z) {
                rz -= pen.z;
            } else {
                rz += pen.z;
            }
        }
    }

    return .{ .x = rx, .y = ry, .z = rz };
}

// ============================================================
// RENDER SYSTEM
// Now outputs BOTH MVP and Model matrices for proper lighting.
// ============================================================

const render_mask = ecs.mask(&.{ .transform, .mesh_renderer });

pub fn buildInstanceBuffer(
    world: *ecs.World,
    view_proj: math.Mat4x4,
    gpu_mvps: [*]math.Mat4x4,
    gpu_models: [*]math.Mat4x4,
) u32 {
    var n: u32 = 0;
    for (0..world.count) |i| {
        if (!ecs.hasMask(world.masks[i], render_mask)) continue;

        const t = &world.transforms[i];

        // Build model matrix: scale → rotate → translate
        const rot = math.Mat4x4.rotateY(t.rot_y);
        var model_mat = rot;

        // Apply uniform scale (projectiles use scale = 0.5)
        model_mat.columns[0][0] *= t.scale;
        model_mat.columns[0][1] *= t.scale;
        model_mat.columns[0][2] *= t.scale;
        model_mat.columns[1][0] *= t.scale;
        model_mat.columns[1][1] *= t.scale;
        model_mat.columns[1][2] *= t.scale;
        model_mat.columns[2][0] *= t.scale;
        model_mat.columns[2][1] *= t.scale;
        model_mat.columns[2][2] *= t.scale;

        model_mat.columns[3][0] = t.x;
        model_mat.columns[3][1] = t.y;
        model_mat.columns[3][2] = t.z;

        gpu_models[n] = model_mat;
        gpu_mvps[n] = math.Mat4x4.mul(view_proj, model_mat);
        n += 1;
    }
    return n;
}
