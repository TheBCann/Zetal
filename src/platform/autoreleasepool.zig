const objc = @import("../objc.zig");

pub const AutoreleasePool = struct {
    handle: objc.Object,

    pub fn init() AutoreleasePool {
        const raw = objc.msgSend(?objc.Object, objc.class("NSAutoreleasePool"), "alloc", .{}) orelse
            @panic("NSAutoreleasePool alloc failed");
        const initialized = objc.msgSend(?objc.Object, raw, "init", .{}) orelse
            @panic("NSAutoreleasePool init failed");
        return .{ .handle = initialized };
    }

    pub fn deinit(self: AutoreleasePool) void {
        objc.msgSend(void, self.handle, "drain", .{});
    }
};
