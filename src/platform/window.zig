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
            .keys = .{false} ** 256,
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
