const std = @import("std");

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

    // Combine two matrices (A * B)
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

    // The Magic Formula for 3D
    pub fn perspective(fov_y_radians: f32, aspect: f32, near: f32, far: f32) Mat4x4 {
        const tan_half_fov = @tan(fov_y_radians / 2.0);
        const y_scale = 1.0 / tan_half_fov;
        const x_scale = y_scale / aspect;

        // FIX: Calculated for Right-Handed Z range [0, 1]
        // scaling z by far / (near - far) ensures we map -near to 0 and -far to 1

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
