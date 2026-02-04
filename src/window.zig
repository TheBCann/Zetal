const std = @import("std");
const objc = @import("objc.zig");

// --- Constants ---
const NSWindowStyleMaskTitled = 1 << 0;
const NSWindowStyleMaskClosable = 1 << 1;
const NSWindowStyleMaskResizable = 1 << 3;
const NSWindowStyleMaskMiniaturizable = 1 << 2;
const DefaultStyle = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable;
const NSBackingStoreBuffered = 2;

// --- Helper Types ---
pub const Rect = extern struct {
    origin_x: f64,
    origin_y: f64,
    width: f64,
    height: f64,
};

pub const Size = extern struct {
    width: f64,
    height: f64,
};

// --- View Logic ---
pub const MetalView = struct {
    handle: objc.Object,
    layer: objc.Object,

    pub fn create(rect: Rect, device_handle: objc.Object) ?MetalView {
        // 1. Create NSView
        const ns_view_class = objc.objc_getClass("NSView");
        const alloc_sel = objc.getSelector("alloc");
        const AllocFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
        const alloc_msg: AllocFn = @ptrCast(&objc.objc_msgSend);
        const raw_view = alloc_msg(ns_view_class, alloc_sel);

        const init_sel = objc.getSelector("initWithFrame:");
        const InitFn = *const fn (?objc.Object, ?objc.Selector, Rect) callconv(.c) ?objc.Object;
        const init_msg: InitFn = @ptrCast(&objc.objc_msgSend);
        const view = init_msg(raw_view, init_sel, rect);

        if (view == null) return null;

        // 2. Create CAMetalLayer
        const layer_class = objc.objc_getClass("CAMetalLayer");
        const layer = alloc_msg(layer_class, alloc_sel);
        const init_layer_sel = objc.getSelector("init");
        const InitLayerFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
        const init_layer_msg: InitLayerFn = @ptrCast(&objc.objc_msgSend);
        _ = init_layer_msg(layer, init_layer_sel);

        // 3. Configure Layer
        // setDevice:
        const setDevice_sel = objc.getSelector("setDevice:");
        const SetDevFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) void;
        const set_dev_msg: SetDevFn = @ptrCast(&objc.objc_msgSend);
        set_dev_msg(layer, setDevice_sel, device_handle);

        // setPixelFormat: (80 = BGRA8Unorm)
        const setPixel_sel = objc.getSelector("setPixelFormat:");
        const SetPixelFn = *const fn (?objc.Object, ?objc.Selector, u64) callconv(.c) void;
        const set_pixel_msg: SetPixelFn = @ptrCast(&objc.objc_msgSend);
        set_pixel_msg(layer, setPixel_sel, 80);

        // 4. Attach Layer to View
        // setLayer:
        const setLayer_sel = objc.getSelector("setLayer:");
        const SetLayerFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) void;
        const set_layer_msg: SetLayerFn = @ptrCast(&objc.objc_msgSend);
        set_layer_msg(view, setLayer_sel, layer);

        // setWantsLayer: YES
        const setWants_sel = objc.getSelector("setWantsLayer:");
        const SetWantsFn = *const fn (?objc.Object, ?objc.Selector, bool) callconv(.c) void;
        const set_wants_msg: SetWantsFn = @ptrCast(&objc.objc_msgSend);
        set_wants_msg(view, setWants_sel, true);

        return MetalView{ .handle = view.?, .layer = layer.? };
    }
};

// --- Window Logic ---
pub const Window = struct {
    handle: objc.Object,

    pub fn create(width: f64, height: f64, title: [:0]const u8) ?Window {
        const ns_window_class = objc.objc_getClass("NSWindow");
        if (ns_window_class == null) return null;

        const alloc_sel = objc.getSelector("alloc");
        const AllocFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
        const alloc_msg: AllocFn = @ptrCast(&objc.objc_msgSend);
        const raw_window = alloc_msg(ns_window_class, alloc_sel);

        const init_sel = objc.getSelector("initWithContentRect:styleMask:backing:defer:");
        const rect = Rect{ .origin_x = 0, .origin_y = 0, .width = width, .height = height };

        const InitFn = *const fn (?objc.Object, ?objc.Selector, Rect, u64, u64, bool) callconv(.c) ?objc.Object;
        const init_msg: InitFn = @ptrCast(&objc.objc_msgSend);

        const win = init_msg(raw_window, init_sel, rect, DefaultStyle, NSBackingStoreBuffered, false);

        if (win) |w| {
            if (objc.createNSString(title)) |ns_title| {
                const setTitle_sel = objc.getSelector("setTitle:");
                const SetTitleFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) void;
                const set_title_msg: SetTitleFn = @ptrCast(&objc.objc_msgSend);
                set_title_msg(w, setTitle_sel, ns_title);
            }

            const center_sel = objc.getSelector("center");
            const CenterFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) void;
            const center_msg: CenterFn = @ptrCast(&objc.objc_msgSend);
            center_msg(w, center_sel);

            const makeKey_sel = objc.getSelector("makeKeyAndOrderFront:");
            const MakeKeyFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) void;
            const make_key_msg: MakeKeyFn = @ptrCast(&objc.objc_msgSend);
            make_key_msg(w, makeKey_sel, null);

            return Window{ .handle = w };
        }
        return null;
    }

    pub fn setContentView(self: Window, view: MetalView) void {
        const sel = objc.getSelector("setContentView:");
        const SetViewFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) void;
        const set_view_msg: SetViewFn = @ptrCast(&objc.objc_msgSend);
        set_view_msg(self.handle, sel, view.handle);
    }
};

pub const App = struct {
    handle: objc.Object,

    pub fn init() App {
        const ns_app_class = objc.objc_getClass("NSApplication");
        const shared_sel = objc.getSelector("sharedApplication");

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
