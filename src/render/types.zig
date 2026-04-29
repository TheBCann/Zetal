const std = @import("std");

pub const MTLPixelFormatDepth32Float: u64 = 252;

pub const MTLCompareFunction = enum(u64) {
    never = 0,
    less = 1,
    equal = 2,
    less_equal = 3,
    greater = 4,
    not_equal = 5,
    greater_equal = 6,
    always = 7,
};

pub const MTLLoadAction = enum(u64) { 
    dont_care = 0,
    load = 1,
    clear = 2,
    _,
};

pub const MTLStoreAction = enum(u64) { 
    dont_care = 0, 
    store = 1, 
    multisample_resolve = 2,
    store_and_multisample_resolve = 3,
    _,
};

pub const MTLClearColor = extern struct {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,
};

pub const MTLPrimitiveType = enum(u64) {
    point = 0,
    line = 1,
    line_strip = 2,
    triangle = 3,
    triangle_strip = 4,
};

// NEW: Index Type
pub const MTLIndexType = enum(u64) {
    uint16 = 0,
    uint32 = 1,
};

pub const MTLPixelFormat = enum(u64) {
    invalid = 0,
    a8_unorm = 1,
    r8_unorm = 10,
    rg8_unorm = 30,
    rgba8_unorm = 70,
    rgba8_unorm_srgb = 71,
    bgra8_unorm = 80,
    bgra8_unorm_srgb = 81,
    rgba16_float = 115,
    rgba32_float = 125,
    depth32_float = 252,
    depth24_unorm_stencil8 = 255,
    depth32_float_stencil8 = 260,
    _,
};

pub const NSWindowStyleMask = struct {
    pub const borderless: u64 = 0;
    pub const titled: u64 = 1 << 0;           // 1
    pub const closable: u64 = 1 << 1;         // 2
    pub const miniaturizable: u64 = 1 << 2;   // 4
    pub const resizable: u64 = 1 << 3;        // 8
    pub const fullscreen: u64 = 1 << 14;
};

pub const NSBackStoreType = enum(u64) {
    retained = 0,
    non_retained = 1,
    buffered = 2,
};

pub const NSEventType = enum(u64) {
    left_mouse_down = 1,
    left_mouse_up = 2,
    right_mouse_down = 3,
    right_mouse_up = 4,
    mouse_moved = 5,
    key_down = 10,
    key_up = 11,
    _,
};
