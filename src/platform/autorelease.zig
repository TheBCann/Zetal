//! NSAutoreleasePool scope: push with `init`, pop with `deinit` (one around startup, one per frame).

const std = @import("std");
const objc = @import("../objc.zig");

/// One NSAutoreleasePool. Everything autoreleased while it is the innermost pool (events, command
/// buffers, encoders, drawables, NSStrings) is released by `deinit`. Main-thread only, strictly LIFO.
pub const AutoreleasePool = struct {
    /// The pool (+1 from alloc/init; -drain releases it).
    handle: objc.Object,

    /// Pushes a new innermost pool; balance it with `deinit` on the same thread.
    pub fn init() AutoreleasePool {
        const handle = objc.msgSend(
            ?objc.Object,
            objc.msgSend(?objc.Object, objc.class("NSAutoreleasePool"), "alloc", .{}),
            "init",
            .{},
        ) orelse @panic("[[NSAutoreleasePool alloc] init] returned nil");
        return .{ .handle = handle };
    }

    /// Drains the pool: releases every object autoreleased into it, then the pool itself.
    pub fn deinit(self: AutoreleasePool) void {
        objc.msgSend(void, self.handle, "drain", .{});
    }
};

// ============================================================
// TESTS (libobjc + Foundation only; no window server)
// ============================================================

const testing = std.testing;

fn retainCount(obj: objc.Object) u64 {
    return objc.msgSend(u64, obj, "retainCount", .{});
}

test "deinit releases what was autoreleased while the pool was innermost" {
    const outer = AutoreleasePool.init();
    defer outer.deinit();
    const obj = objc.new("NSObject") orelse return error.TestUnexpectedResult;
    defer objc.release(obj);

    {
        const inner = AutoreleasePool.init();
        defer inner.deinit();
        _ = objc.msgSend(?objc.Object, objc.retain(obj), "autorelease", .{});
        try testing.expectEqual(2, retainCount(obj)); // the autorelease is still pending
    }
    // Draining the inner pool balanced the retain; the outer pool never saw the object.
    try testing.expectEqual(1, retainCount(obj));
}

test "init hands out a distinct NSAutoreleasePool per scope" {
    const outer = AutoreleasePool.init();
    defer outer.deinit();
    const inner = AutoreleasePool.init();
    defer inner.deinit();
    try testing.expect(outer.handle != inner.handle);
    try testing.expect(objc.msgSend(bool, inner.handle, "isKindOfClass:", .{objc.class("NSAutoreleasePool")}));
}
