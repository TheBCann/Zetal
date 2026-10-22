//! Sound effects through NSSound: load once, restart on every play (the gunshot).

const std = @import("std");
const objc = @import("../objc.zig");

/// One loaded sound file. Main-thread only.
pub const Sound = struct {
    /// The NSSound (+1 from alloc/init; released by `deinit`).
    handle: objc.Object,

    /// Loads the file at `path` (absolute, or relative to the cwd); null when it is missing or
    /// unreadable. Call inside an autorelease pool: the path NSString is autoreleased.
    pub fn load(path: [:0]const u8) ?Sound {
        // Not objc.nsString, which panics on nil: a bad path should only cost us the sound.
        const ns_path = objc.msgSend(?objc.Object, objc.class("NSString"), "stringWithUTF8String:", .{path.ptr}) orelse
            return null;
        // A failing -init releases the alloc'd instance itself, so a nil result leaks nothing.
        const handle = objc.msgSend(
            ?objc.Object,
            objc.msgSend(?objc.Object, objc.class("NSSound"), "alloc", .{}),
            "initWithContentsOfFile:byReference:",
            .{ ns_path, true },
        ) orelse return null;
        return .{ .handle = handle };
    }

    /// Plays from the start, cutting off a play still in progress, so rapid fire retriggers it.
    pub fn play(self: Sound) void {
        // The BOOLs only report whether anything was stopped or started; a dropped shot sound is harmless.
        _ = objc.msgSend(bool, self.handle, "stop", .{});
        _ = objc.msgSend(bool, self.handle, "play", .{});
    }

    /// Releases the NSSound.
    pub fn deinit(self: Sound) void {
        objc.release(self.handle);
    }
};

// ============================================================
// TESTS (AppKit's NSSound class only; no window server, nothing is played)
// ============================================================

const testing = std.testing;
const AutoreleasePool = @import("autorelease.zig").AutoreleasePool;

test "load returns null for a missing file" {
    const pool = AutoreleasePool.init();
    defer pool.deinit();
    try testing.expect(Sound.load("missing.wav") == null);
    try testing.expect(Sound.load("/nonexistent-zetal-dir/gunshot.wav") == null);
}

test "load opens an existing sound file and deinit releases it" {
    const pool = AutoreleasePool.init();
    defer pool.deinit();
    // A stock macOS alert sound, so the test does not depend on the cwd.
    const sound = Sound.load("/System/Library/Sounds/Tink.aiff") orelse return error.SkipZigTest;
    defer sound.deinit();
    try testing.expect(objc.msgSend(bool, sound.handle, "isKindOfClass:", .{objc.class("NSSound")}));
    try testing.expect(!objc.msgSend(bool, sound.handle, "isPlaying", .{}));
}
