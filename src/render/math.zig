const std = @import("std");

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return Vec3{ .x = x, .y = y, .z = z };
    }

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return Vec3{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return Vec3{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub fn scale(a: Vec3, s: f32) Vec3 {
        return Vec3{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return Vec3{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    pub fn norm(a: Vec3) Vec3 {
        const len = std.math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
        if (len == 0) return a;
        return Vec3{ .x = a.x / len, .y = a.y / len, .z = a.z / len };
    }
};

pub const Mat4x4 = struct {
    columns: [4][4]f32,

    pub fn identity() Mat4x4 {
        return Mat4x4{
            .columns = .{
                .{ 1, 0, 0, 0 },
                .{ 0, 1, 0, 0 },
                .{ 0, 0, 1, 0 },
                .{ 0, 0, 0, 1 },
            },
        };
    }

    pub fn mul(a: Mat4x4, b: Mat4x4) Mat4x4 {
        var res = Mat4x4.identity();
        for (0..4) |c| {
            for (0..4) |r| {
                var sum: f32 = 0;
                for (0..4) |k| {
                    sum += a.columns[k][r] * b.columns[c][k];
                }
                res.columns[c][r] = sum;
            }
        }
        return res;
    }

    pub fn translate(x: f32, y: f32, z: f32) Mat4x4 {
        var mat = identity();
        mat.columns[3][0] = x;
        mat.columns[3][1] = y;
        mat.columns[3][2] = z;
        return mat;
    }

    pub fn rotateY(angle_rad: f32) Mat4x4 {
        const c = @cos(angle_rad);
        const s = @sin(angle_rad);
        var mat = identity();
        mat.columns[0][0] = c;
        mat.columns[0][2] = -s;
        mat.columns[2][0] = s;
        mat.columns[2][2] = c;
        return mat;
    }

    pub fn perspective(fov_rad: f32, aspect: f32, near: f32, far: f32) Mat4x4 {
        const tan_half = @tan(fov_rad / 2.0);
        var mat = Mat4x4{ .columns = .{ .{0} ** 4, .{0} ** 4, .{0} ** 4, .{0} ** 4 } };
        mat.columns[0][0] = 1.0 / (aspect * tan_half);
        mat.columns[1][1] = 1.0 / tan_half;
        mat.columns[2][2] = -(far + near) / (far - near);
        mat.columns[2][3] = -1.0;
        mat.columns[3][2] = -(2.0 * far * near) / (far - near);
        return mat;
    }

    // NEW: LookAt Matrix (The standard FPS Camera tool)
    pub fn lookAt(eye: Vec3, center: Vec3, up: Vec3) Mat4x4 {
        const f = Vec3.norm(center.sub(eye));
        const s = Vec3.norm(Vec3.cross(f, up));
        const u = Vec3.cross(s, f);

        var mat = identity();
        mat.columns[0][0] = s.x;
        mat.columns[1][0] = s.y;
        mat.columns[2][0] = s.z;
        mat.columns[0][1] = u.x;
        mat.columns[1][1] = u.y;
        mat.columns[2][1] = u.z;
        mat.columns[0][2] = -f.x;
        mat.columns[1][2] = -f.y;
        mat.columns[2][2] = -f.z;
        mat.columns[3][0] = -Vec3.dot(s, eye);
        mat.columns[3][1] = -Vec3.dot(u, eye);
        mat.columns[3][2] = Vec3.dot(f, eye);
        return mat;
    }
};

// ============================================================
// RAY-AABB INTERSECTION (Slab Method)
// ============================================================

/// Cast a ray and test against an axis-aligned bounding box.
/// Returns the distance `t` along the ray to the nearest hit, or null if miss.
/// `dir` must be normalized.
pub fn rayIntersectAABB(origin: Vec3, dir: Vec3, box_min: Vec3, box_max: Vec3) ?f32 {
    var tmin: f32 = std.math.inf(f32);
    var tmax: f32 = std.math.inf(f32);

    // X slab
    if (@abs(dir.x) > 1e-8) {
        const t1 = (box_min.x - origin.x) / dir.x;
        const t2 = (box_max.x - origin.x) / dir.x;
        tmin = @max(tmin, @min(t1, t2));
        tmax = @max(tmax, @min(t1, t2));
    } else if (origin.x < box_min.x or origin.x > box_max.x) {
        return null;
    }

    // Y slab
    if (@abs(dir.y) > 1e-8) {
        const t1 = (box_min.y - origin.y) / dir.y;
        const t2 = (box_max.y - origin.y) / dir.y;
        tmin = @max(tmin, @min(t1, t2));
        tmax = @max(tmax, @min(t1, t2));
    } else if (origin.y < box_min.y or origin.y > box_max.y) {
        return null;
    }

    // Z slab
    if (@abs(dir.z) > 1e-8) {
        const t1 = (box_min.z - origin.z) / dir.z;
        const t2 = (box_max.z - origin.z) / dir.z;
        tmin = @max(tmin, @min(t1, t2));
        tmax = @max(tmax, @min(t1, t2));
    } else if (origin.z < box_min.z or origin.z > box_max.z) {
        return null;
    }

    if (tmax < 0 or tmin > tmax) return null;

    // Return nearest positive t
    return if (tmin >= 0) tmin else tmax;
}
