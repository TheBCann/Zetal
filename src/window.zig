const std = @import("std");
const objc = @import("objc.zig");

pub const Keys = enum(u16) {
    A = 0, S = 1, D = 2, W = 13,
    Q = 12, E = 14,
    Space = 49, Escape = 53,
    Left = 123, Right = 124, Down = 125, Up = 126,
};

pub const App = struct {
    handle: ?*anyopaque,
    key_states: [128]bool = [_]bool{false} ** 128,

    pub fn init() App {
        const app_class = objc.objc_getClass("NSApplication");
        const shared_sel = objc.getSelector("sharedApplication");
        const SharedFn = *const fn (?*anyopaque, ?objc.Selector) callconv(.c) ?*anyopaque;
        const shared_msg: SharedFn = @ptrCast(&objc.objc_msgSend);
        const app = shared_msg(app_class, shared_sel);

        const policy_sel = objc.getSelector("setActivationPolicy:");
        const PolicyFn = *const fn (?*anyopaque, ?objc.Selector, isize) callconv(.c) bool;
        const policy_msg: PolicyFn = @ptrCast(&objc.objc_msgSend);
        _ = policy_msg(app, policy_sel, 0); 

        return App{ .handle = app };
    }

    pub fn isPressed(self: App, key: Keys) bool {
        return self.key_states[@intFromEnum(key)];
    }

    pub fn pollEvents(self: *App) void {
        const app = self.handle;
        
        const next_event_sel = objc.getSelector("nextEventMatchingMask:untilDate:inMode:dequeue:");
        const type_sel = objc.getSelector("type");
        const key_code_sel = objc.getSelector("keyCode");
        
        const str_class = objc.objc_getClass("NSString");
        const str_sel = objc.getSelector("stringWithUTF8String:");
        const StrFn = *const fn (?*anyopaque, ?objc.Selector, [*:0]const u8) callconv(.c) ?*anyopaque;
        const str_msg: StrFn = @ptrCast(&objc.objc_msgSend);
        const mode = str_msg(str_class, str_sel, "kCFRunLoopDefaultMode");

        const NextEventFn = *const fn (?*anyopaque, ?objc.Selector, u64, ?*anyopaque, ?*anyopaque, bool) callconv(.c) ?*anyopaque;
        const next_event: NextEventFn = @ptrCast(&objc.objc_msgSend);
        
        const TypeFn = *const fn (?*anyopaque, ?objc.Selector) callconv(.c) u64;
        const get_type: TypeFn = @ptrCast(&objc.objc_msgSend);

        const KeyFn = *const fn (?*anyopaque, ?objc.Selector) callconv(.c) u16;
        const get_key: KeyFn = @ptrCast(&objc.objc_msgSend);

        while (true) {
            const event = next_event(app, next_event_sel, 18446744073709551615, null, mode, true);
            
            if (event) |e| {
                const event_type = get_type(e, type_sel);
                
                if (event_type == 10) { // KeyDown
                    const code = get_key(e, key_code_sel);
                    if (code < 128) self.key_states[code] = true;
                } else if (event_type == 11) { // KeyUp
                    const code = get_key(e, key_code_sel);
                    if (code < 128) self.key_states[code] = false;
                }

                const send_sel = objc.getSelector("sendEvent:");
                const SendFn = *const fn (?*anyopaque, ?objc.Selector, ?*anyopaque) callconv(.c) void;
                const send_msg: SendFn = @ptrCast(&objc.objc_msgSend);
                send_msg(app, send_sel, e);
            } else {
                break; 
            }
        }
    }
};

pub const Window = struct {
    handle: ?*anyopaque,

    pub const Rect = extern struct {
        x: f64, y: f64, w: f64, h: f64,
    };

    pub fn create(width: f64, height: f64, title: [:0]const u8) ?Window {
        const win_class = objc.objc_getClass("NSWindow");
        const alloc_sel = objc.getSelector("alloc");
        const init_sel = objc.getSelector("initWithContentRect:styleMask:backing:defer:");
        
        const AllocFn = *const fn (?*anyopaque, ?objc.Selector) callconv(.c) ?*anyopaque;
        const alloc_msg: AllocFn = @ptrCast(&objc.objc_msgSend);
        const raw_win = alloc_msg(win_class, alloc_sel);

        const rect = Rect{ .x = 0, .y = 0, .w = width, .h = height };
        const style: u64 = 1 | 2 | 4 | 8; 

        const InitFn = *const fn (?*anyopaque, ?objc.Selector, Rect, u64, u64, bool) callconv(.c) ?*anyopaque;
        const init_msg: InitFn = @ptrCast(&objc.objc_msgSend);
        const win = init_msg(raw_win, init_sel, rect, style, 2, false);

        const title_sel = objc.getSelector("setTitle:");
        const str_class = objc.objc_getClass("NSString");
        const str_sel = objc.getSelector("stringWithUTF8String:");
        
        const StrFn = *const fn (?*anyopaque, ?objc.Selector, [*:0]const u8) callconv(.c) ?*anyopaque;
        const str_msg: StrFn = @ptrCast(&objc.objc_msgSend);
        const ns_title = str_msg(str_class, str_sel, title);

        const SetTitleFn = *const fn (?*anyopaque, ?objc.Selector, ?*anyopaque) callconv(.c) void;
        const set_title: SetTitleFn = @ptrCast(&objc.objc_msgSend);
        set_title(win, title_sel, ns_title);

        const center_sel = objc.getSelector("center");
        _ = objc.objc_msgSend(win, center_sel);

        const order_sel = objc.getSelector("makeKeyAndOrderFront:");
        const OrderFn = *const fn (?*anyopaque, ?objc.Selector, ?*anyopaque) callconv(.c) void;
        const order_msg: OrderFn = @ptrCast(&objc.objc_msgSend);
        order_msg(win, order_sel, null);

        return Window{ .handle = win };
    }

    pub fn setContentView(self: Window, view: MetalView) void {
        const sel = objc.getSelector("setContentView:");
        const SetFn = *const fn (?*anyopaque, ?objc.Selector, ?*anyopaque) callconv(.c) void;
        const msg: SetFn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel, view.handle);
    }
};

pub const MetalView = struct {
    handle: ?*anyopaque,

    pub const Rect = extern struct {
        origin_x: f64, origin_y: f64, width: f64, height: f64,
    };

    pub fn create(frame: Rect, device_handle: *anyopaque) ?MetalView {
        // NOTE: We stripped MTKView logic to ensure consistent fallback behavior for this fix
        // In a production app, you would link MetalKit and use MTKView properly.
        
        const nsview_class = objc.objc_getClass("NSView");
        const alloc_sel = objc.getSelector("alloc");
        const init_sel = objc.getSelector("initWithFrame:");
        
        const AllocFn = *const fn (?*anyopaque, ?objc.Selector) callconv(.c) ?*anyopaque;
        const alloc_msg: AllocFn = @ptrCast(&objc.objc_msgSend);
        const raw_view = alloc_msg(nsview_class, alloc_sel);

        const InitFn = *const fn (?*anyopaque, ?objc.Selector, Rect) callconv(.c) ?*anyopaque;
        const init_msg: InitFn = @ptrCast(&objc.objc_msgSend);
        const view = init_msg(raw_view, init_sel, frame);

        const setWantsLayer_sel = objc.getSelector("setWantsLayer:");
        const SetBoolFn = *const fn (?*anyopaque, ?objc.Selector, bool) callconv(.c) void;
        const set_bool: SetBoolFn = @ptrCast(&objc.objc_msgSend);
        set_bool(view, setWantsLayer_sel, true);

        const layer_class = objc.objc_getClass("CAMetalLayer");
        const layer_sel = objc.getSelector("layer");
        const layer_msg: AllocFn = @ptrCast(&objc.objc_msgSend); 
        const layer = layer_msg(layer_class, layer_sel); 

        const setDevice_sel = objc.getSelector("setDevice:");
        const SetObjFn = *const fn (?*anyopaque, ?objc.Selector, *anyopaque) callconv(.c) void;
        const set_dev: SetObjFn = @ptrCast(&objc.objc_msgSend);
        set_dev(layer, setDevice_sel, device_handle);

        const setLayer_sel = objc.getSelector("setLayer:");
        const SetLayerFn = *const fn (?*anyopaque, ?objc.Selector, ?*anyopaque) callconv(.c) void;
        const set_layer: SetLayerFn = @ptrCast(&objc.objc_msgSend);
        set_layer(view, setLayer_sel, layer);

        // FIX: Return the View, not the Layer
        return MetalView{ .handle = view }; 
    }

    pub fn nextDrawable(self: MetalView) ?*anyopaque {
        if (self.handle) |view_handle| {
            // 1. Get the Layer from the View
            const layer_sel = objc.getSelector("layer");
            const GetLayerFn = *const fn (?*anyopaque, ?objc.Selector) callconv(.c) ?*anyopaque;
            const get_layer: GetLayerFn = @ptrCast(&objc.objc_msgSend);
            const layer = get_layer(view_handle, layer_sel);

            if (layer) |l| {
                // 2. Call nextDrawable on the Layer
                const next_sel = objc.getSelector("nextDrawable");
                const NextFn = *const fn (?*anyopaque, ?objc.Selector) callconv(.c) ?*anyopaque;
                const msg: NextFn = @ptrCast(&objc.objc_msgSend);
                return msg(l, next_sel);
            }
        }
        return null;
    }
};

test "App Initialization" {
    const app = App.init();
    try std.testing.expect(app.handle != null);
}
