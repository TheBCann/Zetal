const std = @import("std");
const objc = @import("objc.zig");

pub const App = struct {
    pool: objc.Object,
    ns_app: objc.Object,
    running: bool,
    keys: [256]bool,
    mouse_dx: f32 = 0,
    mouse_dy: f32 = 0,

    pub const KeyCode = enum(u8) {
        A = 0x00,
        S = 0x01,
        D = 0x02,
        W = 0x0D,
        Q = 0x0C,
        E = 0x0E,
        Escape = 0x35,
    };

    pub fn init() App {
        const pool_class = objc.objc_getClass("NSAutoreleasePool");
        const alloc = objc.getSelector("alloc");
        const init_sel = objc.getSelector("init");

        const AllocFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
        const alloc_msg: AllocFn = @ptrCast(&objc.objc_msgSend);
        var pool = alloc_msg(pool_class, alloc);

        const InitFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
        const init_msg: InitFn = @ptrCast(&objc.objc_msgSend);
        pool = init_msg(pool, init_sel);

        const app_class = objc.objc_getClass("NSApplication");
        const shared_sel = objc.getSelector("sharedApplication");
        const SharedFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
        const shared_msg: SharedFn = @ptrCast(&objc.objc_msgSend);
        const ns_app = shared_msg(app_class, shared_sel);

        const setPol_sel = objc.getSelector("setActivationPolicy:");
        const SetPolFn = *const fn (?*anyopaque, ?*anyopaque, i64) callconv(.c) bool;
        const pol_msg: SetPolFn = @ptrCast(&objc.objc_msgSend);
        _ = pol_msg(ns_app, setPol_sel, 0);

        return App{
            .pool = pool.?,
            .ns_app = ns_app.?,
            .running = true,
            .keys = .{false} ** 256,
        };
    }

    pub fn pollEvents(self: *App) void {
        self.mouse_dx = 0;
        self.mouse_dy = 0;

        const next_sel = objc.getSelector("nextEventMatchingMask:untilDate:inMode:dequeue:");
        const NextFn = *const fn (?*anyopaque, ?*anyopaque, u64, ?*anyopaque, ?*anyopaque, bool) callconv(.c) ?*anyopaque;
        const next_msg: NextFn = @ptrCast(&objc.objc_msgSend);

        // FIX: Explicitly cast the function to take a C-string pointer
        const str_class = objc.objc_getClass("NSString");
        const str_sel = objc.getSelector("stringWithUTF8String:");
        const StrFn = *const fn (?*anyopaque, ?*anyopaque, [*]const u8) callconv(.c) ?*anyopaque;
        const str_msg: StrFn = @ptrCast(&objc.objc_msgSend);

        // Use the casted function with a string literal
        const default_mode = str_msg(str_class, str_sel, "kCFRunLoopDefaultMode");

        while (true) {
            const event = next_msg(self.ns_app, next_sel, 18446744073709551615, null, default_mode, true);
            if (event == null) break;

            const type_sel = objc.getSelector("type");
            const TypeFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) u64;
            const type_msg: TypeFn = @ptrCast(&objc.objc_msgSend);
            const evt_type = type_msg(event, type_sel);

            if (evt_type == 10) { // KeyDown
                const code_sel = objc.getSelector("keyCode");
                const CodeFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) u16;
                const code_msg: CodeFn = @ptrCast(&objc.objc_msgSend);
                const code = code_msg(event, code_sel);
                if (code < 256) self.keys[code] = true;
                if (code == 0x35) self.running = false;
            } else if (evt_type == 11) { // KeyUp
                const code_sel = objc.getSelector("keyCode");
                const CodeFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) u16;
                const code_msg: CodeFn = @ptrCast(&objc.objc_msgSend);
                const code = code_msg(event, code_sel);
                if (code < 256) self.keys[code] = false;
            } else if (evt_type == 5) { // MouseMoved
                const dx_sel = objc.getSelector("deltaX");
                const dy_sel = objc.getSelector("deltaY");
                const DeltaFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) f64;
                const delta_msg: DeltaFn = @ptrCast(&objc.objc_msgSend);

                self.mouse_dx += @as(f32, @floatCast(delta_msg(event, dx_sel)));
                self.mouse_dy += @as(f32, @floatCast(delta_msg(event, dy_sel)));
            }

            const send_sel = objc.getSelector("sendEvent:");
            const SendFn = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void;
            const send_msg: SendFn = @ptrCast(&objc.objc_msgSend);
            send_msg(self.ns_app, send_sel, event);
        }
    }

    pub fn isPressed(self: App, key: KeyCode) bool {
        return self.keys[@intFromEnum(key)];
    }
};

pub const Window = struct {
    handle: objc.Object,
    pub fn create(w: f64, h: f64, title: []const u8) ?Window {
        const class = objc.objc_getClass("NSWindow");
        const alloc_sel = objc.getSelector("alloc");
        const AllocFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
        const alloc_msg: AllocFn = @ptrCast(&objc.objc_msgSend);
        const ptr = alloc_msg(class, alloc_sel);

        const init_sel = objc.getSelector("initWithContentRect:styleMask:backing:defer:");
        const rect = objc.CGRect{ .origin_x = 0, .origin_y = 0, .width = w, .height = h };
        const style: u64 = 1 | 2 | 4 | 8;

        const InitFn = *const fn (?objc.Object, ?objc.Selector, objc.CGRect, u64, u64, bool) callconv(.c) ?objc.Object;
        const init_msg: InitFn = @ptrCast(&objc.objc_msgSend);
        const win = init_msg(ptr, init_sel, rect, style, 2, false);

        if (win) |window| {
            const str_class = objc.objc_getClass("NSString");
            const str_sel = objc.getSelector("stringWithUTF8String:");
            const StrFn = *const fn (?objc.Object, ?objc.Selector, [*]const u8) callconv(.c) ?objc.Object;
            const str_msg: StrFn = @ptrCast(&objc.objc_msgSend);
            const title_obj = str_msg(str_class, str_sel, title.ptr);

            const setTitle_sel = objc.getSelector("setTitle:");
            const SetTitleFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) void;
            const setTitle_msg: SetTitleFn = @ptrCast(&objc.objc_msgSend);
            setTitle_msg(window, setTitle_sel, title_obj);

            const center_sel = objc.getSelector("center");
            const CenterFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) void;
            const center_msg: CenterFn = @ptrCast(&objc.objc_msgSend);
            center_msg(window, center_sel);

            const makeKey_sel = objc.getSelector("makeKeyAndOrderFront:");
            const MakeKeyFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) void;
            const makeKey_msg: MakeKeyFn = @ptrCast(&objc.objc_msgSend);
            makeKey_msg(window, makeKey_sel, null);

            const setAccepts_sel = objc.getSelector("setAcceptsMouseMovedEvents:");
            const SetAcceptsFn = *const fn (?objc.Object, ?objc.Selector, bool) callconv(.c) void;
            const setAccepts_msg: SetAcceptsFn = @ptrCast(&objc.objc_msgSend);
            setAccepts_msg(window, setAccepts_sel, true);

            const cursor_class = objc.objc_getClass("NSCursor");
            const hide_sel = objc.getSelector("hide");
            const HideFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) void;
            const hide_msg: HideFn = @ptrCast(&objc.objc_msgSend);
            hide_msg(cursor_class, hide_sel);

            return Window{ .handle = window };
        }
        return null;
    }

    pub fn setContentView(self: Window, view: MetalView) void {
        const sel = objc.getSelector("setContentView:");
        const Fn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) void;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel, view.handle);
    }
};

pub const MetalView = struct {
    handle: objc.Object,
    pub fn create(rect: objc.CGRect, device: objc.Object) ?MetalView {
        const class = objc.objc_getClass("MTKView");
        const alloc_sel = objc.getSelector("alloc");
        const AllocFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
        const alloc_msg: AllocFn = @ptrCast(&objc.objc_msgSend);
        const ptr = alloc_msg(class, alloc_sel);

        const init_sel = objc.getSelector("initWithFrame:device:");
        const InitFn = *const fn (?objc.Object, ?objc.Selector, objc.CGRect, ?objc.Object) callconv(.c) ?objc.Object;
        const init_msg: InitFn = @ptrCast(&objc.objc_msgSend);
        if (init_msg(ptr, init_sel, rect, device)) |view| {
            return MetalView{ .handle = view };
        }
        return null;
    }
    pub fn nextDrawable(self: MetalView) ?objc.Object {
        const sel = objc.getSelector("currentDrawable");
        const Fn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        return msg(self.handle, sel);
    }
};
