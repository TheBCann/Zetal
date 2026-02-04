const std = @import("std");

pub const MTLLoadAction = enum(u64) {
    DontCare = 0,
    Load = 1,
    Clear = 2,
};

pub const MTLStoreAction = enum(u64) {
    DontCare = 0,
    Store = 1,
    MultisampleResolve = 2,
};

pub const MTLClearColor = extern struct {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,
};
