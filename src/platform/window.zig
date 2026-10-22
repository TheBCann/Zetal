<<<<<<< HEAD
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
||||||| empty tree
=======
const std = @import("std");
const objc = @import("../objc.zig");
const types = @import("../render/types.zig");

const msgSend = objc.msgSend;
const Object = objc.Object;

pub const App = struct {
    pool: objc.Object,
    ns_app: objc.Object,
    default_run_loop: objc.Object,
    running: bool,
    keys: [256]bool,
    mouse_dx: f32 = 0,
    mouse_dy: f32 = 0,
    mouse_left: bool = false,
    mouse_left_pressed: bool = false,
    mouse_right: bool = false,
    mouse_right_pressed: bool = false,

    pub const KeyCode = enum(u8) {
        A = 0x00,
        S = 0x01,
        D = 0x02,
        W = 0x0D,
        Q = 0x0C,
        E = 0x0E,
        Space = 0x31,
        Escape = 0x35,
    };

    pub fn init() App {
        const pool_class = objc.class("NSAutoreleasePool");
        const uinit_pool = msgSend(?Object, pool_class, "alloc", .{});
        const pool = msgSend(?Object, uinit_pool, "init", .{});

        const app_class = objc.class("NSApplication");
        const shared_app = msgSend(?Object, app_class, "sharedApplication", .{});

        msgSend(void, shared_app, "setActivationPolicy:", .{@as(i64, 0)});

        const window_class = objc.class("NSWindow");
        const uinit_window = msgSend(?Object, window_class, "alloc", .{});

        const frame = objc.CGRect{
            .origin_x = 0,
            .origin_y = 0,
            .width = 800,
            .height = 600,
        };

        const style_mask = types.NSWindowStyleMask.titled
            | types.NSWindowStyleMask.closable
            | types.NSWindowStyleMask.resizable;

        const backing_store = @intFromEnum(types.NSBackStoreType.buffered);

        const window = msgSend(?Object, uinit_window, "initWithContentRect:styleMask:backing:defer:", .{
            frame,
            style_mask,
            backing_store,
            false,
        });

        msgSend(void, window, "center", .{});
        msgSend(void, window, "makeKeyAndOrderFront:", .{@as(?Object, null)});

        const str_class = objc.class("NSString");
        const mode_str = msgSend(?Object, str_class, "stringWithUTF8String:", .{
            @as([*]const u8, @ptrCast("kCFRunLoopDefaultMode")),
        }).?;
        _ = objc.retain(mode_str);

        return App{
            .pool = pool.?,
            .ns_app = shared_app.?,
            .default_run_loop = mode_str,
            .running = true,
            .keys = @splat(false),
        };
    }

    pub fn pollEvents(self: *App) void {
        self.mouse_dx = 0;
        self.mouse_dy = 0;
        self.mouse_left_pressed = false;
        self.mouse_right_pressed = false;

        while (true) {
            const event = msgSend(?Object, self.ns_app, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{
                @as(u64, std.math.maxInt(u64)),
                @as(?Object, null),
                self.default_run_loop,
                true,
            });

            if (event == null) break;

            if (event) |evt| {
                const evt_type: types.NSEventType = @enumFromInt(msgSend(u64, evt, "type", .{}));

                switch (evt_type) {
                    .key_down => {
                        const code = msgSend(u16, evt, "keyCode", .{});
                        if (code < 256) self.keys[code] = true;
                        if (code == 0x35) self.running = false;
                    },
                    .key_up => {
                        const code = msgSend(u16, evt, "keyCode", .{});
                        if (code < 256) self.keys[code] = false;
                    },
                    .mouse_moved => {
                        self.mouse_dx += @as(f32, @floatCast(msgSend(f64, evt, "deltaX", .{})));
                        self.mouse_dy += @as(f32, @floatCast(msgSend(f64, evt, "deltaY", .{})));
                    },
                    .left_mouse_down => {
                        self.mouse_left = true;
                        self.mouse_left_pressed = true;
                    },
                    .left_mouse_up => {
                        self.mouse_left = false;
                    },
                    .right_mouse_down => {
                        self.mouse_right = true;
                        self.mouse_right_pressed = true;
                    },
                    .right_mouse_up => {
                        self.mouse_right = false;
                    },
                    else => {},
                }

                msgSend(void, self.ns_app, "sendEvent:", .{evt});
            }
        }
    }

    pub fn isPressed(self: App, key: KeyCode) bool {
        return self.keys[@intFromEnum(key)];
    }
};

pub const Window = struct {
    handle: objc.Object,

    pub fn create(w: f64, h: f64, title: []const u8) ?Window {
        const class = objc.class("NSWindow");
        const uninit_window = msgSend(?Object, class, "alloc", .{});

        const rect = objc.CGRect{ .origin_x = 0, .origin_y = 0, .width = w, .height = h };
        const style: u64 = 1 | 2 | 4 | 8;

        const win = msgSend(?Object, uninit_window, "initWithContentRect:styleMask:backing:defer:", .{
            rect,
            style,
            @as(u64, 2), // buffered
            false,
        });

        if (win) |window| {
            const str_class = objc.class("NSString");
            const title_obj = msgSend(?Object, str_class, "stringWithUTF8String:", .{title.ptr});

            msgSend(void, window, "setTitle:", .{title_obj});
            msgSend(void, window, "center", .{});
            msgSend(void, window, "makeKeyAndOrderFront:", .{@as(?Object, null)});
            msgSend(void, window, "setAcceptsMouseMovedEvents:", .{true});

            const cursor_class = objc.class("NSCursor");
            msgSend(void, cursor_class, "hide", .{});

            return Window{ .handle = window };
        }
        return null;
    }

    pub fn setContentView(self: Window, view: MetalView) void {
        msgSend(void, self.handle, "setContentView:", .{view.handle});
    }
};

pub const MetalView = struct {
    handle: objc.Object,

    pub fn create(rect: objc.CGRect, device: objc.Object) ?MetalView {
        const class = objc.class("MTKView");
        const uninit_view = msgSend(?Object, class, "alloc", .{});

        const view = msgSend(?Object, uninit_view, "initWithFrame:device:", .{rect, device});
        if (view) |v| {
            return MetalView{ .handle = v };
        }
        return null;
    }

    pub fn nextDrawable(self: MetalView) ?objc.Object {
        return msgSend(?Object, self.handle, "currentDrawable", .{});
    }
};
>>>>>>> Zetal/main
