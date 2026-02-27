const std = @import("std");
const ecs = @import("world.zig");
const math = @import("../render/root.zig").math;
const compute = @import("../render/compute.zig");

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
// ============================================================

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
        } else if (!a_static) {
            // A is dynamic, B is static
            world.transforms[i].x += push_x;
            world.transforms[i].y += push_y;
            world.transforms[i].z += push_z;

            if (push_x != 0) world.velocities[i].x *= -restitution;
            if (push_y != 0) world.velocities[i].y *= -restitution;
            if (push_z != 0) world.velocities[i].z *= -restitution;
        } else if (!b_static) {
            // B is dynamic, A is static
            world.transforms[j].x -= push_x;
            world.transforms[j].y -= push_y;
            world.transforms[j].z -= push_z;

            if (push_x != 0) world.velocities[j].x *= -restitution;
            if (push_y != 0) world.velocities[j].y *= -restitution;
            if (push_z != 0) world.velocities[j].z *= -restitution;
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

        // Build model matrix: rotate then translate
        const rot = math.Mat4x4.rotateY(t.rot_y);
        var model_mat = rot;
        model_mat.columns[3][0] = t.x;
        model_mat.columns[3][1] = t.y;
        model_mat.columns[3][2] = t.z;

        gpu_models[n] = model_mat;
        gpu_mvps[n] = math.Mat4x4.mul(view_proj, model_mat);
        n += 1;
    }
    return n;
}
