const std = @import("std");

// 4x4 Matrix (Column-Major order for Metal)
pub const Mat4x4 = extern struct {
    columns: [4][4]f32,

    pub fn identity() Mat4x4 {
        return .{
            .columns = .{
                .{ 1.0, 0.0, 0.0, 0.0 }, // Col 1
                .{ 0.0, 1.0, 0.0, 0.0 }, // Col 2
                .{ 0.0, 0.0, 1.0, 0.0 }, // Col 3
                .{ 0.0, 0.0, 0.0, 1.0 }, // Col 4
            },
        };
    }

    pub fn rotateZ(angle_radians: f32) Mat4x4 {
        const c = @cos(angle_radians);
        const s = @sin(angle_radians);

        return .{
            .columns = .{
                .{ c, s, 0.0, 0.0 }, // X Axis rotated
                .{ -s, c, 0.0, 0.0 }, // Y Axis rotated
                .{ 0.0, 0.0, 1.0, 0.0 }, // Z Axis (unchanged)
                .{ 0.0, 0.0, 0.0, 1.0 }, // W (Identity)
            },
        };
    }
};
