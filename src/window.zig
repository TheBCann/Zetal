const std = @import("std");
const objc = @import("objc.zig");

// --- AppKit Constants ---
const NSWindowStyleMaskTitled = 1 << 0;
const NSWindowStyleMaskClosable = 1 << 1;
const NSWindowStyleMaskResizable = 1 << 3;
const NSWindowStyleMaskMiniaturizable = 1 << 2;

const DefaultStyle = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable;
const NSBackingStoreBuffered = 2;

pub const Rect = extern struct {
    origin_x: f64,
    origin_y: f64,
    width: f64,
    height: f64,
};

pub const Window = struct {
    handle: objc.Object,

    pub fn create(width: f64, height: f64, title: [:0]const u8) ?Window {
        const ns_window_class = objc.objc_getClass("NSWindow");
        if (ns_window_class == null) return null;

        // 1. Alloc
        const alloc_sel = objc.getSelector("alloc");
        const AllocFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
        const alloc_msg: AllocFn = @ptrCast(&objc.objc_msgSend);
        const raw_window = alloc_msg(ns_window_class, alloc_sel);

        // 2. Init
        const init_sel = objc.getSelector("initWithContentRect:styleMask:backing:defer:");
        const rect = Rect{ .origin_x = 0, .origin_y = 0, .width = width, .height = height };

        const InitFn = *const fn (?objc.Object, ?objc.Selector, Rect, u64, u64, bool) callconv(.c) ?objc.Object;
        const init_msg: InitFn = @ptrCast(&objc.objc_msgSend);

        const win = init_msg(raw_window, init_sel, rect, DefaultStyle, NSBackingStoreBuffered, false);

        if (win) |w| {
            // 3. Set Title (Strict Cast)
            if (objc.createNSString(title)) |ns_title| {
                const setTitle_sel = objc.getSelector("setTitle:");
                const SetTitleFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) void;
                const set_title_msg: SetTitleFn = @ptrCast(&objc.objc_msgSend);
                set_title_msg(w, setTitle_sel, ns_title);
            }

            // 4. Center (Strict Cast)
            const center_sel = objc.getSelector("center");
            const CenterFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) void;
            const center_msg: CenterFn = @ptrCast(&objc.objc_msgSend);
            center_msg(w, center_sel);

            // 5. Make Key (Strict Cast)
            const makeKey_sel = objc.getSelector("makeKeyAndOrderFront:");
            const MakeKeyFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) void;
            const make_key_msg: MakeKeyFn = @ptrCast(&objc.objc_msgSend);
            make_key_msg(w, makeKey_sel, null);

            return Window{ .handle = w };
        }
        return null;
    }
};

pub const App = struct {
    handle: objc.Object,

    pub fn init() App {
        const ns_app_class = objc.objc_getClass("NSApplication");
        const shared_sel = objc.getSelector("sharedApplication");

        // Strict cast for sharedApplication (takes no args, returns Object)
        const SharedAppFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
        const shared_app_msg: SharedAppFn = @ptrCast(&objc.objc_msgSend);
        const app = shared_app_msg(ns_app_class, shared_sel);

        const policy_sel = objc.getSelector("setActivationPolicy:");
        const PolicyFn = *const fn (?objc.Object, ?objc.Selector, isize) callconv(.c) void;
        const policy_msg: PolicyFn = @ptrCast(&objc.objc_msgSend);
        policy_msg(app, policy_sel, 0);

        return App{ .handle = app.? };
    }

    pub fn run(self: App) void {
        const run_sel = objc.getSelector("run");
        const RunFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) void;
        const run_msg: RunFn = @ptrCast(&objc.objc_msgSend);
        run_msg(self.handle, run_sel);
    }
};
