const std = @import("std");
const ecs = @import("ecs.zig");
const math = @import("render/root.zig").math;

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
// VELOCITY SYSTEM
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
// COLLISION SYSTEM
// Detects AABB overlaps between all collidable entities.
// Resolves by pushing non-static entities apart along the
// axis of least penetration (minimum translation vector).
// ============================================================

const collider_mask = ecs.mask(&.{ .transform, .collider });

pub fn collisionSystem(world: *ecs.World) void {
    // O(n^2) broad phase — fine for < 500 entities
    var i: u32 = 0;
    while (i < world.count) : (i += 1) {
        if (!ecs.hasMask(world.masks[i], collider_mask)) continue;

        var j: u32 = i + 1;
        while (j < world.count) : (j += 1) {
            if (!ecs.hasMask(world.masks[j], collider_mask)) continue;

            const a_box = ecs.AABB.fromTransformCollider(&world.transforms[i], &world.colliders[i]);
            const b_box = ecs.AABB.fromTransformCollider(&world.transforms[j], &world.colliders[j]);

            if (!a_box.overlaps(b_box)) continue;

            // Both static — no resolution needed
            if (world.colliders[i].is_static and world.colliders[j].is_static) continue;

            // Compute penetration on each axis
            const pen = a_box.penetration(b_box);
            if (pen.x <= 0 or pen.y <= 0 or pen.z <= 0) continue;

            // Push apart along axis of LEAST penetration (MTV)
            const abs_x = pen.x;
            const abs_y = pen.y;
            const abs_z = pen.z;

            var push_x: f32 = 0;
            var push_y: f32 = 0;
            var push_z: f32 = 0;

            if (abs_x <= abs_y and abs_x <= abs_z) {
                // X is shallowest
                if (world.transforms[i].x < world.transforms[j].x) {
                    push_x = -abs_x;
                } else {
                    push_x = abs_x;
                }
            } else if (abs_y <= abs_x and abs_y <= abs_z) {
                // Y is shallowest
                if (world.transforms[i].y < world.transforms[j].y) {
                    push_y = -abs_y;
                } else {
                    push_y = abs_y;
                }
            } else {
                // Z is shallowest
                if (world.transforms[i].z < world.transforms[j].z) {
                    push_z = -abs_z;
                } else {
                    push_z = abs_z;
                }
            }

            // Apply push — split between non-static entities
            const a_static = world.colliders[i].is_static;
            const b_static = world.colliders[j].is_static;

            if (!a_static and !b_static) {
                // Both dynamic — split the push
                world.transforms[i].x += push_x * 0.5;
                world.transforms[i].y += push_y * 0.5;
                world.transforms[i].z += push_z * 0.5;
                world.transforms[j].x -= push_x * 0.5;
                world.transforms[j].y -= push_y * 0.5;
                world.transforms[j].z -= push_z * 0.5;
            } else if (!a_static) {
                // Only A moves
                world.transforms[i].x += push_x;
                world.transforms[i].y += push_y;
                world.transforms[i].z += push_z;
            } else {
                // Only B moves
                world.transforms[j].x -= push_x;
                world.transforms[j].y -= push_y;
                world.transforms[j].z -= push_z;
            }
        }
    }
}

// ============================================================
// CAMERA COLLISION
// Checks camera position against all collidable entities.
// Returns an adjusted camera position pushed out of any AABB.
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

    // Treat camera as a small AABB
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

        // Push camera out along axis of least penetration
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
// ============================================================

const render_mask = ecs.mask(&.{ .transform, .mesh_renderer });

pub fn buildInstanceBuffer(
    world: *ecs.World,
    view_proj: math.Mat4x4,
    gpu_mvps: [*]math.Mat4x4,
) u32 {
    var n: u32 = 0;
    for (0..world.count) |i| {
        if (!ecs.hasMask(world.masks[i], render_mask)) continue;

        const t = &world.transforms[i];

        const rot = math.Mat4x4.rotateY(t.rot_y);
        var model_mat = rot;
        model_mat.columns[3][0] = t.x;
        model_mat.columns[3][1] = t.y;
        model_mat.columns[3][2] = t.z;

        gpu_mvps[n] = math.Mat4x4.mul(view_proj, model_mat);
        n += 1;
    }
    return n;
}
