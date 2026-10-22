//! Engine math: Vec3, column-major Mat4 (laid out like MSL float4x4), Metal projections, ray/AABB test.
const std = @import("std");

// ============================================================
// Vec3
// ============================================================

/// A 3-component f32 vector used for positions, directions and velocities.
pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    /// The origin / null vector.
    pub const zero: Vec3 = .{ .x = 0, .y = 0, .z = 0 };

    /// Returns the vector (x, y, z).
    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    /// Returns a + b.
    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    /// Returns a - b.
    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    /// Returns a scaled by s.
    pub fn scale(a: Vec3, s: f32) Vec3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }

    /// Returns the dot product a · b.
    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    /// Returns the right-handed cross product a × b.
    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    /// Returns the Euclidean length |a|.
    pub fn length(a: Vec3) f32 {
        return @sqrt(a.dot(a));
    }

    /// Returns a / |a|, or `a` unchanged when its length is 0 (so a zero direction never turns into NaNs).
    pub fn normalize(a: Vec3) Vec3 {
        const len = a.length();
        if (len == 0) return a;
        // Divide per component (not multiply by 1/len) to match the original's rounding bit for bit.
        return .{ .x = a.x / len, .y = a.y / len, .z = a.z / len };
    }
};

// ============================================================
// Mat4
// ============================================================

/// A 4×4 f32 matrix stored column-major: `columns[c][r]` is row r of column c, the exact 64-byte layout
/// of an MSL `float4x4`, so instance buffers and `setVertexBytes` can take it unconverted.
pub const Mat4 = extern struct {
    columns: [4][4]f32,

    /// The identity matrix.
    pub const identity: Mat4 = .{ .columns = .{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    } };

    /// Returns the product a · b (b is applied first when transforming a point).
    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var out: Mat4 = .{ .columns = @splat(@splat(0)) };
        for (0..4) |c| {
            for (0..4) |r| {
                var sum: f32 = 0;
                for (0..4) |k| sum += a.columns[k][r] * b.columns[c][k];
                out.columns[c][r] = sum;
            }
        }
        return out;
    }

    /// Returns the matrix that translates points by (x, y, z).
    pub fn translation(x: f32, y: f32, z: f32) Mat4 {
        var m = identity;
        m.columns[3] = .{ x, y, z, 1 };
        return m;
    }

    /// Returns the rotation by `radians` about +y; with column 0 = (c, 0, -s, 0), π/2 turns +x into -z.
    pub fn rotationY(radians: f32) Mat4 {
        const c = @cos(radians);
        const s = @sin(radians);
        return .{ .columns = .{
            .{ c, 0, -s, 0 },
            .{ 0, 1, 0, 0 },
            .{ s, 0, c, 0 },
            .{ 0, 0, 0, 1 },
        } };
    }

    /// Returns a right-handed perspective projection for Metal clip space: view-space z = -near maps to
    /// depth 0 and z = -far to depth 1 (`fov_y` in radians, `aspect` = width / height).
    pub fn perspective(fov_y: f32, aspect: f32, near: f32, far: f32) Mat4 {
        // The original used the OpenGL matrix (z_ndc in [-1, 1]); Metal clips z_ndc < 0, which moved
        // the effective near plane from 0.1 out to about 0.2.
        const tan_half = @tan(fov_y / 2.0);
        var m: Mat4 = .{ .columns = @splat(@splat(0)) };
        m.columns[0][0] = 1.0 / (aspect * tan_half);
        m.columns[1][1] = 1.0 / tan_half;
        m.columns[2][2] = far / (near - far);
        m.columns[2][3] = -1.0;
        m.columns[3][2] = near * far / (near - far);
        return m;
    }

    /// Returns a right-handed orthographic projection mapping the box to x, y in [-1, 1] and
    /// view-space z = -near / -far to depth 0 / 1 (Metal clip space).
    pub fn orthographic(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Mat4 {
        const width = right - left;
        const height = top - bottom;
        const depth = far - near;
        var m = identity;
        m.columns[0][0] = 2.0 / width;
        m.columns[1][1] = 2.0 / height;
        m.columns[2][2] = -1.0 / depth;
        m.columns[3][0] = -(right + left) / width;
        m.columns[3][1] = -(top + bottom) / height;
        m.columns[3][2] = -near / depth;
        return m;
    }

    /// Returns the right-handed view matrix of a camera at `eye` looking at `target`: the eye lands on the
    /// origin, the view direction on -z and `up` (projected) on +y.
    pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
        const f = target.sub(eye).normalize();
        const s = f.cross(up).normalize();
        const u = s.cross(f);
        return .{ .columns = .{
            .{ s.x, u.x, -f.x, 0 },
            .{ s.y, u.y, -f.y, 0 },
            .{ s.z, u.z, -f.z, 0 },
            .{ -s.dot(eye), -u.dot(eye), f.dot(eye), 1 },
        } };
    }

    /// Returns m · (p, 1) as homogeneous (x, y, z, w); divide by w after a perspective projection.
    pub fn transformPoint(m: Mat4, p: Vec3) [4]f32 {
        var out: [4]f32 = undefined;
        for (&out, 0..) |*v, r| {
            v.* = m.columns[0][r] * p.x + m.columns[1][r] * p.y + m.columns[2][r] * p.z + m.columns[3][r];
        }
        return out;
    }
};

// ============================================================
// Ray / AABB intersection (slab method)
// ============================================================

/// Returns the ray parameter t ≥ 0 of the nearest point where `origin + t·dir` meets the box (the exit
/// distance when `origin` is inside it), or null on a miss. t is in units of |dir|: pass a normalized
/// `dir` to get world distance.
pub fn rayIntersectAABB(origin: Vec3, dir: Vec3, box_min: Vec3, box_max: Vec3) ?f32 {
    var t_min = -std.math.inf(f32);
    var t_max = std.math.inf(f32);
    // One helper for all three axes: the original's copy-pasted Z slab widened t_max with @max instead
    // of narrowing it, so rays that crossed the box's X/Y extent but not its Z extent still "hit".
    if (!clipSlab(origin.x, dir.x, box_min.x, box_max.x, &t_min, &t_max)) return null;
    if (!clipSlab(origin.y, dir.y, box_min.y, box_max.y, &t_min, &t_max)) return null;
    if (!clipSlab(origin.z, dir.z, box_min.z, box_max.z, &t_min, &t_max)) return null;
    if (t_max < 0 or t_min > t_max) return null;
    return if (t_min >= 0) t_min else t_max;
}

/// Narrows [t_min, t_max] to the part of the ray inside one axis slab [lo, hi]; returns false when a ray
/// parallel to the slab starts outside it (no t can ever enter).
fn clipSlab(origin: f32, dir: f32, lo: f32, hi: f32, t_min: *f32, t_max: *f32) bool {
    if (@abs(dir) > 1e-8) {
        const t1 = (lo - origin) / dir;
        const t2 = (hi - origin) / dir;
        t_min.* = @max(t_min.*, @min(t1, t2));
        t_max.* = @min(t_max.*, @max(t1, t2));
        return true;
    }
    return origin >= lo and origin <= hi;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn expectVec3Approx(expected: Vec3, actual: Vec3, tolerance: f32) !void {
    try testing.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try testing.expectApproxEqAbs(expected.y, actual.y, tolerance);
    try testing.expectApproxEqAbs(expected.z, actual.z, tolerance);
}

fn expectPointApprox(expected: [4]f32, actual: [4]f32, tolerance: f32) !void {
    for (expected, actual) |e, a| try testing.expectApproxEqAbs(e, a, tolerance);
}

fn expectMat4Approx(expected: Mat4, actual: Mat4, tolerance: f32) !void {
    for (expected.columns, actual.columns) |e, a| try expectPointApprox(e, a, tolerance);
}

/// Fails cleanly (instead of panicking on `.?`) when the ray missed.
fn expectHit(expected: f32, hit: ?f32, tolerance: f32) !void {
    try testing.expectApproxEqAbs(expected, hit orelse return error.TestUnexpectedResult, tolerance);
}

/// Projects `p` and divides by w, i.e. returns normalized device coordinates (x, y, depth).
fn ndc(m: Mat4, p: Vec3) Vec3 {
    const clip = m.transformPoint(p);
    return .init(clip[0] / clip[3], clip[1] / clip[3], clip[2] / clip[3]);
}

test "Vec3 arithmetic, length and normalize" {
    const a = Vec3.init(1, 2, 3);
    const b = Vec3.init(-4, 5, 0.5);
    try expectVec3Approx(.init(-3, 7, 3.5), a.add(b), 1e-6);
    try expectVec3Approx(.init(5, -3, 2.5), a.sub(b), 1e-6);
    try expectVec3Approx(.init(2, 4, 6), a.scale(2), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 7.5), a.dot(b), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 5), Vec3.init(3, 4, 0).length(), 1e-6);

    // Right-handed: x × y = z, and the product is perpendicular to both inputs.
    try expectVec3Approx(.init(0, 0, 1), Vec3.init(1, 0, 0).cross(.init(0, 1, 0)), 1e-6);
    try expectVec3Approx(.init(-1, 0, 0), Vec3.init(0, 0, 1).cross(.init(0, 1, 0)), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), a.cross(b).dot(a), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), a.cross(b).dot(b), 1e-5);

    try expectVec3Approx(.init(0.6, 0.8, 0), Vec3.init(3, 4, 0).normalize(), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), b.normalize().length(), 1e-6);
    try testing.expectEqual(Vec3.zero, Vec3.zero.normalize());
}

test "Mat4 is 64 bytes, column-major like MSL float4x4" {
    try testing.expectEqual(@as(usize, 64), @sizeOf(Mat4));
    const m = Mat4.translation(1, 2, 3);
    const flat: *const [16]f32 = @ptrCast(&m);
    // Column 3 (floats 12..15) carries the translation, as a float4x4's fourth column does.
    try testing.expectEqualSlices(f32, &.{ 1, 2, 3, 1 }, flat[12..16]);
    try testing.expectEqualSlices(f32, &.{ 1, 0, 0, 0 }, flat[0..4]);
}

test "Mat4.mul: identity is neutral and products apply right to left" {
    const m = Mat4.translation(1, -2, 3).mul(Mat4.rotationY(0.7));
    try expectMat4Approx(m, Mat4.identity.mul(m), 1e-6);
    try expectMat4Approx(m, m.mul(Mat4.identity), 1e-6);

    // (T · R) · p == T · (R · p): rotate first, then translate.
    const p = Vec3.init(2, 5, -1);
    const rotated = Mat4.rotationY(0.7).transformPoint(p);
    const expected = Vec3.init(rotated[0] + 1, rotated[1] - 2, rotated[2] + 3);
    try expectPointApprox(.{ expected.x, expected.y, expected.z, 1 }, m.transformPoint(p), 1e-5);
}

test "translation moves points and keeps w = 1" {
    try expectPointApprox(.{ 5, 7, 9, 1 }, Mat4.translation(1, 2, 3).transformPoint(.init(4, 5, 6)), 1e-6);
}

test "rotationY(pi/2) maps +x to -z and +z to +x" {
    const r = Mat4.rotationY(std.math.pi / 2.0);
    try expectPointApprox(.{ 0, 0, -1, 1 }, r.transformPoint(.init(1, 0, 0)), 1e-6);
    try expectPointApprox(.{ 1, 0, 0, 1 }, r.transformPoint(.init(0, 0, 1)), 1e-6);
    try expectPointApprox(.{ 0, 1, 0, 1 }, r.transformPoint(.init(0, 1, 0)), 1e-6);
}

test "perspective maps -near to depth 0 and -far to depth 1 (Metal clip space)" {
    const fov_y = std.math.degreesToRadians(@as(f32, 45));
    const aspect: f32 = 4.0 / 3.0;
    const near: f32 = 0.1;
    const far: f32 = 200;
    const p = Mat4.perspective(fov_y, aspect, near, far);

    // f32 rounding gives ~7e-8 at near and ~1.0000001 at far: compare approximately, never `<= 1`.
    try testing.expectApproxEqAbs(@as(f32, 0), ndc(p, .init(0, 0, -near)).z, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), ndc(p, .init(0, 0, -far)).z, 1e-6);
    try testing.expectApproxEqAbs(near, p.transformPoint(.init(0, 0, -near))[3], 1e-6); // w = -z

    // Regression (§6.7): geometry just past the near plane is visible; the GL-style matrix clipped
    // everything closer than ~0.2.
    const just_past_near = ndc(p, .init(0, 0, -0.15)).z;
    try testing.expect(just_past_near > 0 and just_past_near < 1);

    // The frustum edges at distance 10 land on the NDC borders, so the FOV and aspect are unchanged.
    const tan_half = @tan(fov_y / 2.0);
    try testing.expectApproxEqAbs(@as(f32, 1), ndc(p, .init(0, tan_half * 10, -10)).y, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), ndc(p, .init(aspect * tan_half * 10, 0, -10)).x, 1e-6);
}

test "orthographic maps near to depth 0, far to depth 1 and the box edges to +-1" {
    const light = Mat4.orthographic(-30, 30, -30, 30, 0.1, 60);
    try testing.expectApproxEqAbs(@as(f32, 0), light.transformPoint(.init(0, 0, -0.1))[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), light.transformPoint(.init(0, 0, -60))[2], 1e-6);
    try expectPointApprox(.{ 1, -1, 0.5, 1 }, light.transformPoint(.init(30, -30, -30.05)), 1e-6);

    // An off-centre box exercises the translation column.
    const box = Mat4.orthographic(0, 10, 0, 5, 1, 3);
    try expectPointApprox(.{ -1, -1, 0, 1 }, box.transformPoint(.init(0, 0, -1)), 1e-6);
    try expectPointApprox(.{ 1, 1, 1, 1 }, box.transformPoint(.init(10, 5, -3)), 1e-6);
}

test "lookAt moves the eye to the origin and the target onto -z" {
    // The shadow light's camera (main.zig SUN_POS -> SUN_TARGET).
    const eye = Vec3.init(10, 20, 10);
    const target = Vec3.init(0, -5, -10);
    const view = Mat4.lookAt(eye, target, .init(0, 1, 0));
    try expectPointApprox(.{ 0, 0, 0, 1 }, view.transformPoint(eye), 1e-5);
    const distance = target.sub(eye).length();
    try expectPointApprox(.{ 0, 0, -distance, 1 }, view.transformPoint(target), 1e-5);

    // Axis-aligned camera on +z looking at the origin: world x/y stay x/y, so the basis is right-handed.
    const front = Mat4.lookAt(.init(0, 0, 5), Vec3.zero, .init(0, 1, 0));
    try expectPointApprox(.{ 1, 2, -5, 1 }, front.transformPoint(.init(1, 2, 0)), 1e-6);
}

test "rayIntersectAABB: hit, miss, inside, behind, parallel" {
    const lo = Vec3.init(-1, -1, -1);
    const hi = Vec3.init(1, 1, 1);
    const down_z = Vec3.init(0, 0, -1);

    try expectHit(4, rayIntersectAABB(.init(0, 0, 5), down_z, lo, hi), 1e-6);
    try testing.expectEqual(null, rayIntersectAABB(.init(0, 0, 5), Vec3.init(1, 0, -1).normalize(), lo, hi));
    // From inside, the nearest t >= 0 is the exit point.
    try expectHit(1, rayIntersectAABB(Vec3.zero, .init(1, 0, 0), lo, hi), 1e-6);
    // The box lies behind the ray.
    try testing.expectEqual(null, rayIntersectAABB(.init(0, 0, 5), .init(0, 0, 1), lo, hi));
    // Parallel to the y slab: outside it never enters, inside it hits normally.
    try testing.expectEqual(null, rayIntersectAABB(.init(0, 2, 5), down_z, lo, hi));
    try expectHit(4, rayIntersectAABB(.init(0, 0.5, 5), down_z, lo, hi), 1e-6);
}

test "rayIntersectAABB regression: the Z slab narrows t_max" {
    const dir = Vec3.init(1, 0, -1).normalize();
    // The ray crosses x in [10, 11] at z ~ -10, far past this box's z in [-2, -1]: a miss.
    // The original's Z slab returned 14.142 here.
    try testing.expectEqual(null, rayIntersectAABB(Vec3.zero, dir, .init(10, -1, -2), .init(11, 1, -1)));
    // The same diagonal ray still hits a box that really straddles its path.
    try expectHit(14.142136, rayIntersectAABB(Vec3.zero, dir, .init(10, -1, -12), .init(11, 1, -9)), 1e-5);
}
