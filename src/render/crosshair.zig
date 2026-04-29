// Crosshair overlay — thin + shape rendered in screen space (NDC).
// No depth test, drawn last in the frame.

pub const crosshair_source: [:0]const u8 = @embedFile("crosshair.msl");

// --- Standard Crosshair Dimensions ---
const arm_len: f32 = 0.020;
const gap: f32 = 0.006;
const thick: f32 = 0.0015;
const dot: f32 = 0.0015;
const arm_end: f32 = gap + arm_len;

// --- Hitmarker Dimensions ('X' shape) ---
const hm_gap: f32 = 0.015;
const hm_len: f32 = 0.015;
const hm_thick: f32 = 0.001;
const hm_end: f32 = hm_gap + hm_len;

// Helper to rotate vertices 45 degrees and flag w=2 for the shader
fn hv(x: f32, y: f32) [4]f32 {
    const c45: f32 = 0.70710678;
    return .{
        (x - y) * c45,
        (x + y) * c45,
        0.0,
        2.0, // w=2 tells the Metal shader this is a hitmarker!
    };
}

pub const VERT_COUNT: u32 = 54; // 30 (crosshair) + 24 (hitmarker)

pub const vertices = [VERT_COUNT][4]f32{
    // ==========================================
    // STANDARD CROSSHAIR (w = 1)
    // ==========================================
    // Left arm
    .{ -arm_end, -thick, 0, 1 }, .{ -gap, -thick, 0, 1 },    .{ -gap, thick, 0, 1 },
    .{ -arm_end, -thick, 0, 1 }, .{ -gap, thick, 0, 1 },     .{ -arm_end, thick, 0, 1 },
    // Right arm
    .{ gap, -thick, 0, 1 },      .{ arm_end, -thick, 0, 1 }, .{ arm_end, thick, 0, 1 },
    .{ gap, -thick, 0, 1 },      .{ arm_end, thick, 0, 1 },  .{ gap, thick, 0, 1 },
    // Top arm
    .{ -thick, gap, 0, 1 },      .{ thick, gap, 0, 1 },      .{ thick, arm_end, 0, 1 },
    .{ -thick, gap, 0, 1 },      .{ thick, arm_end, 0, 1 },  .{ -thick, arm_end, 0, 1 },
    // Bottom arm
    .{ -thick, -arm_end, 0, 1 }, .{ thick, -arm_end, 0, 1 }, .{ thick, -gap, 0, 1 },
    .{ -thick, -arm_end, 0, 1 }, .{ thick, -gap, 0, 1 },     .{ -thick, -gap, 0, 1 },
    // Center dot
    .{ -dot, -dot, 0, 1 },       .{ dot, -dot, 0, 1 },       .{ dot, dot, 0, 1 },
    .{ -dot, -dot, 0, 1 },       .{ dot, dot, 0, 1 },        .{ -dot, dot, 0, 1 },

    // ==========================================
    // HITMARKER (w = 2, rotated 45 deg by helper)
    // ==========================================
    // Top-Right arm
    hv(hm_gap, -hm_thick), hv(hm_end, -hm_thick), hv(hm_end, hm_thick),
    hv(hm_gap, -hm_thick), hv(hm_end, hm_thick),  hv(hm_gap, hm_thick),
    // Bottom-Left arm
    hv(-hm_end, -hm_thick), hv(-hm_gap, -hm_thick), hv(-hm_gap, hm_thick),
    hv(-hm_end, -hm_thick), hv(-hm_gap, hm_thick),  hv(-hm_end, hm_thick),
    // Top-Left arm
    hv(-hm_thick, hm_gap), hv(hm_thick, hm_gap), hv(hm_thick, hm_end),
    hv(-hm_thick, hm_gap), hv(hm_thick, hm_end), hv(-hm_thick, hm_end),
    // Bottom-Right arm
    hv(-hm_thick, -hm_end), hv(hm_thick, -hm_end), hv(hm_thick, -hm_gap),
    hv(-hm_thick, -hm_end), hv(hm_thick, -hm_gap), hv(-hm_thick, -hm_gap),
};
