// Crosshair overlay — thin + shape rendered in screen space (NDC).
// No depth test, drawn last in the frame.

pub const crosshair_source: [:0]const u8 = @embedFile("crosshair.msl");

// 4 arms + center dot = 5 quads = 30 vertices
// Each vertex is float4 (x, y, z, w) in NDC space.
// Aspect ratio correction happens in the shader.

const arm_len: f32 = 0.025; // Length of each arm
const gap: f32 = 0.006; // Gap from center to arm start
const thick: f32 = 0.002; // Half-thickness of each arm
const dot: f32 = 0.002; // Half-size of center dot

const arm_end: f32 = gap + arm_len;

pub const VERT_COUNT: u32 = 30;

pub const vertices = [VERT_COUNT][4]f32{
    // Left arm: x [-arm_end, -gap], y [-thick, thick]
    .{ -arm_end, -thick, 0, 1 }, .{ -gap, -thick, 0, 1 },    .{ -gap, thick, 0, 1 },
    .{ -arm_end, -thick, 0, 1 }, .{ -gap, thick, 0, 1 },     .{ -arm_end, thick, 0, 1 },

    // Right arm: x [gap, arm_end], y [-thick, thick]
    .{ gap, -thick, 0, 1 },      .{ arm_end, -thick, 0, 1 }, .{ arm_end, thick, 0, 1 },
    .{ gap, -thick, 0, 1 },      .{ arm_end, thick, 0, 1 },  .{ gap, thick, 0, 1 },

    // Top arm: x [-thick, thick], y [gap, arm_end]
    .{ -thick, gap, 0, 1 },      .{ thick, gap, 0, 1 },      .{ thick, arm_end, 0, 1 },
    .{ -thick, gap, 0, 1 },      .{ thick, arm_end, 0, 1 },  .{ -thick, arm_end, 0, 1 },

    // Bottom arm: x [-thick, thick], y [-arm_end, -gap]
    .{ -thick, -arm_end, 0, 1 }, .{ thick, -arm_end, 0, 1 }, .{ thick, -gap, 0, 1 },
    .{ -thick, -arm_end, 0, 1 }, .{ thick, -gap, 0, 1 },     .{ -thick, -gap, 0, 1 },

    // Center dot: x [-dot, dot], y [-dot, dot]
    .{ -dot, -dot, 0, 1 },       .{ dot, -dot, 0, 1 },       .{ dot, dot, 0, 1 },
    .{ -dot, -dot, 0, 1 },       .{ dot, dot, 0, 1 },        .{ -dot, dot, 0, 1 },
};
