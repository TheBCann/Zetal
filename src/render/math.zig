const std = @import("std");
pub const types = @import("types.zig");
pub const pass = @import("pass.zig");
pub const pipeline = @import("pipeline.zig");
pub const shader = @import("shader.zig");
pub const vertex = @import("vertex.zig");
pub const math = @import("math.zig");

pub const Mat4x4 = extern struct {
    columns: [4][4]f32,

    pub fn identity() Mat4x4 {
        return .{
            .columns = .{
                .{ 1.0, 0.0, 0.0, 0.0 },
                .{ 0.0, 1.0, 0.0, 0.0 },
                .{ 0.0, 0.0, 1.0, 0.0 },
                .{ 0.0, 0.0, 0.0, 1.0 },
            },
        };
    }

    pub fn mul(a: Mat4x4, b: Mat4x4) Mat4x4 {
        var res = Mat4x4.identity();
        for (0..4) |c| {
            for (0..4) |r| {
                var sum: f32 = 0.0;
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

    pub fn rotateY(angle_radians: f32) Mat4x4 {
        const c = @cos(angle_radians);
        const s = @sin(angle_radians);
        return .{
            .columns = .{
                .{ c, 0.0, -s, 0.0 },
                .{ 0.0, 1.0, 0.0, 0.0 },
                .{ s, 0.0, c, 0.0 },
                .{ 0.0, 0.0, 0.0, 1.0 },
            },
        };
    }

    pub fn perspective(fov_y_radians: f32, aspect: f32, near: f32, far: f32) Mat4x4 {
        const tan_half_fov = @tan(fov_y_radians / 2.0);
        const y_scale = 1.0 / tan_half_fov;
        const x_scale = y_scale / aspect;

        return .{
            .columns = .{
                .{ x_scale, 0.0, 0.0, 0.0 },
                .{ 0.0, y_scale, 0.0, 0.0 },
                .{ 0.0, 0.0, far / (near - far), -1.0 },
                .{ 0.0, 0.0, (far * near) / (near - far), 0.0 },
            },
        };
    }
};

test "Mat4x4 Identity" {
    const id = Mat4x4.identity();
    try std.testing.expectEqual(id.columns[0][0], 1.0);
    try std.testing.expectEqual(id.columns[1][1], 1.0);
    try std.testing.expectEqual(id.columns[2][2], 1.0);
    try std.testing.expectEqual(id.columns[3][3], 1.0);
}

test "Mat4x4 Translation" {
    const t = Mat4x4.translate(10.0, 20.0, 30.0);
    try std.testing.expectEqual(t.columns[3][0], 10.0); // X
    try std.testing.expectEqual(t.columns[3][1], 20.0); // Y
    try std.testing.expectEqual(t.columns[3][2], 30.0); // Z
}

test "Mat4x4 Multiplication" {
    // Identity * Translate should equal Translate
    const id = Mat4x4.identity();
    const t = Mat4x4.translate(5.0, 5.0, 5.0);
    const res = Mat4x4.mul(id, t);

    try std.testing.expectEqual(res.columns[3][0], 5.0);
}
