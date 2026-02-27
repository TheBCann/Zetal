const std = @import("std");

pub const MTLPixelFormatDepth32Float: u64 = 252;

pub const MTLCompareFunction = enum(u64) {
    Never = 0,
    Less = 1,
    Equal = 2,
    LessEqual = 3,
    Greater = 4,
    NotEqual = 5,
    GreaterEqual = 6,
    Always = 7,
};

pub const MTLLoadAction = enum(u64) { DontCare = 0, Load = 1, Clear = 2 };
pub const MTLStoreAction = enum(u64) { DontCare = 0, Store = 1, MultisampleResolve = 2 };

pub const MTLClearColor = extern struct {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,
};

pub const MTLPrimitiveType = enum(u64) {
    Point = 0,
    Line = 1,
    LineStrip = 2,
    Triangle = 3,
    TriangleStrip = 4,
};

// NEW: Index Type
pub const MTLIndexType = enum(u64) {
    UInt16 = 0,
    UInt32 = 1,
};
