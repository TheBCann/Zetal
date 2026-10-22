//! The game window: one NSWindow around a paused MTKView whose CAMetalLayer hands out vsync-paced drawables.

const std = @import("std");
const objc = @import("../objc.zig");
const App = @import("app.zig").App;

// ============================================================
// APPKIT / METAL CONSTANTS (SDK headers: NSWindow.h, NSGraphics.h, MTLPixelFormat.h)
// ============================================================

const NSWindowStyleMaskTitled: u64 = 1 << 0;
const NSWindowStyleMaskClosable: u64 = 1 << 1;
const NSWindowStyleMaskMiniaturizable: u64 = 1 << 2;
const NSWindowStyleMaskResizable: u64 = 1 << 3;
const NSBackingStoreBuffered: u64 = 2;
// Must match the colour attachment format of the renderer's pipelines (metal.PixelFormat.bgra8_unorm).
const MTLPixelFormatBGRA8Unorm: u64 = 80;

// ============================================================
// WINDOW
// ============================================================

/// The game's only window. Owns the NSWindow and the MTKView (+1 each). Main-thread only; call
/// `create` and `nextDrawable` inside an autorelease pool.
pub const Window = struct {
    /// The NSWindow (+1 from alloc/init; releasedWhenClosed is NO, so closing never frees it).
    ns_window: objc.Object,
    /// Its content view, an MTKView (+1 from alloc/init; the window holds its own reference).
    view: objc.Object,
    /// The view's CAMetalLayer (owned by the view; not retained here).
    layer: objc.Object,
    /// The drawable size last pushed into `layer`, in pixels; 0x0 until the first `nextDrawable`.
    applied_size: objc.CGSize = .{ .width = 0, .height = 0 },

    /// Opens a centred window with a `width` x `height`-point content area titled `title`, holding a
    /// Metal view on `device` (an MTLDevice), orders it front and hides the cursor. Fails with
    /// error.WindowCreateFailed or error.ViewCreateFailed when AppKit returns nil.
    pub fn create(device: objc.Object, width: f64, height: f64, title: [:0]const u8) !Window {
        const content_rect: objc.CGRect = .{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = width, .height = height },
        };
        const style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
            NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;

        const ns_window = objc.msgSend(
            ?objc.Object,
            objc.msgSend(?objc.Object, objc.class("NSWindow"), "alloc", .{}),
            "initWithContentRect:styleMask:backing:defer:",
            .{ content_rect, style, NSBackingStoreBuffered, false },
        ) orelse return error.WindowCreateFailed;
        errdefer objc.release(ns_window);
        // The default (YES) would make -close free the window while we still hold its +1.
        objc.msgSend(void, ns_window, "setReleasedWhenClosed:", .{false});
        objc.msgSend(void, ns_window, "setTitle:", .{objc.nsString(title)});
        // Off by default, and without it there are no MouseMoved events, so no mouse look.
        objc.msgSend(void, ns_window, "setAcceptsMouseMovedEvents:", .{true});
        objc.msgSend(void, ns_window, "center", .{});

        const view = objc.msgSend(
            ?objc.Object,
            objc.msgSend(?objc.Object, objc.class("MTKView"), "alloc", .{}),
            "initWithFrame:device:",
            .{ content_rect, device },
        ) orelse return error.ViewCreateFailed;
        errdefer objc.release(view);
        objc.msgSend(void, view, "setColorPixelFormat:", .{MTLPixelFormatBGRA8Unorm});
        // The game loop drives frames: no MTKView timer and no setNeedsDisplay redraws. autoResizeDrawable
        // keeps its default (YES), so -drawableSize follows the view's size in pixels (see nextDrawable).
        objc.msgSend(void, view, "setPaused:", .{true});
        objc.msgSend(void, view, "setEnableSetNeedsDisplay:", .{false});

        objc.msgSend(void, ns_window, "setContentView:", .{view});
        const layer = objc.msgSend(?objc.Object, view, "layer", .{}) orelse return error.ViewCreateFailed;
        objc.msgSend(void, ns_window, "makeKeyAndOrderFront:", .{@as(?objc.Object, null)});
        // Hide/unhide calls are counted: deinit's +unhide balances this one.
        objc.msgSend(void, objc.class("NSCursor"), "hide", .{});
        return .{ .ns_window = ns_window, .view = view, .layer = layer };
    }

    /// Shows the cursor again, closes the window (fine if the user already did) and releases the
    /// view and the window.
    pub fn deinit(self: *Window) void {
        objc.msgSend(void, objc.class("NSCursor"), "unhide", .{});
        objc.msgSend(void, self.ns_window, "close", .{});
        objc.release(self.view);
        objc.release(self.ns_window);
        self.* = undefined;
    }

    /// True until the user closes the window. A miniaturized window, or any window of a hidden app
    /// (Cmd-H), reports isVisible == NO without being closed, so both count as open.
    pub fn isOpen(self: Window, app: *const App) bool {
        return objc.msgSend(bool, self.ns_window, "isVisible", .{}) or
            objc.msgSend(bool, self.ns_window, "isMiniaturized", .{}) or
            app.isHidden();
    }

    /// The view's drawable size in pixels (content size x backing scale), which tracks resizes.
    pub fn drawableSize(self: Window) objc.CGSize {
        return objc.msgSend(objc.CGSize, self.view, "drawableSize", .{});
    }

    /// Returns the layer's next drawable (autoreleased), or null when none frees up in time (the
    /// layer's ~1 s timeout); this call is where the loop waits for vsync.
    pub fn nextDrawable(self: *Window) ?objc.Object {
        // A paused MTKView only copies its auto-resized drawableSize into the layer inside -draw,
        // which we never call, so copy it here; otherwise drawables keep their first size (probed on screen).
        const size = self.drawableSize();
        if (layerNeedsResize(size, self.applied_size)) {
            objc.msgSend(void, self.layer, "setDrawableSize:", .{size});
            self.applied_size = size;
        }
        return objc.msgSend(?objc.Object, self.layer, "nextDrawable", .{});
    }

    /// Resizes the content area to `width` x `height` points (the smoke run's resize check).
    pub fn setContentSize(self: Window, width: f64, height: f64) void {
        const size: objc.CGSize = .{ .width = width, .height = height };
        objc.msgSend(void, self.ns_window, "setContentSize:", .{size});
    }
};

/// True when the view's drawable size must be pushed to the layer: it changed since the last push,
/// and it is at least 1x1 (a collapsed view reports 0, which the layer cannot use).
fn layerNeedsResize(size: objc.CGSize, applied: objc.CGSize) bool {
    if (size.width < 1 or size.height < 1) return false;
    return size.width != applied.width or size.height != applied.height;
}

// ============================================================
// TESTS — the layer-size sync rule (window code itself needs the window server, so it is not unit-tested)
// ============================================================

const testing = std.testing;

fn cgSize(width: f64, height: f64) objc.CGSize {
    return .{ .width = width, .height = height };
}

test "the first real drawable size is pushed to the layer" {
    try testing.expect(layerNeedsResize(cgSize(1600, 1200), cgSize(0, 0)));
}

test "an unchanged drawable size is not pushed again" {
    try testing.expect(!layerNeedsResize(cgSize(1600, 1200), cgSize(1600, 1200)));
}

test "a resize in either dimension is pushed" {
    try testing.expect(layerNeedsResize(cgSize(1280, 960), cgSize(1600, 1200)));
    try testing.expect(layerNeedsResize(cgSize(1600, 960), cgSize(1600, 1200)));
    try testing.expect(layerNeedsResize(cgSize(1280, 1200), cgSize(1600, 1200)));
}

test "empty or sub-pixel sizes are never pushed" {
    try testing.expect(!layerNeedsResize(cgSize(0, 0), cgSize(0, 0)));
    try testing.expect(!layerNeedsResize(cgSize(0, 600), cgSize(1600, 1200)));
    try testing.expect(!layerNeedsResize(cgSize(800, 0.5), cgSize(1600, 1200)));
}
