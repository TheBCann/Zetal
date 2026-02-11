const std = @import("std");
const root = @import("root.zig");
const window = @import("window.zig");
const render = @import("render/root.zig");
const objc = @import("objc.zig");

pub const Core = struct {
    device: root.MetalDevice,
    queue: root.MetalCommandQueue,
    app: window.App,
    win: window.Window,
    view: window.MetalView,
    depth_texture: objc.Object,

    const CGSize = extern struct { width: f64, height: f64 };

    pub fn init() !Core {
        // 1. System Setup
        const device = root.MetalDevice.createSystemDefault() orelse return error.NoDevice;
        const queue = device.createCommandQueue() orelse return error.NoQueue;
        const app = window.App.init();

        // 2. Window Setup
        const win = window.Window.create(800, 600, "Zetal Engine") orelse return error.WindowFailed;
        const view = window.MetalView.create(.{ .origin_x = 0, .origin_y = 0, .width = 800, .height = 600 }, device.handle) orelse return error.ViewFailed;
        win.setContentView(view);

        // 3. Query ACTUAL pixel size from MTKView (Retina-aware)
        //    On a 2x Retina display, an 800x600 point window = 1600x1200 pixels.
        //    The depth texture MUST match the drawable's pixel dimensions.
        const size_sel = objc.getSelector("drawableSize");
        const SizeFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) CGSize;
        const size_msg: SizeFn = @ptrCast(&objc.objc_msgSend);
        const drawable_size = size_msg(view.handle, size_sel);
        const pixel_w: u64 = @intFromFloat(drawable_size.width);
        const pixel_h: u64 = @intFromFloat(drawable_size.height);

        // 4. Shared Resources (Depth Buffer at pixel resolution)
        const depth_texture = device.createDepthTexture(pixel_w, pixel_h) orelse return error.DepthTextureFailed;

        return Core{
            .device = device,
            .queue = queue,
            .app = app,
            .win = win,
            .view = view,
            .depth_texture = depth_texture,
        };
    }

    pub fn pollEvents(self: *Core) void {
        self.app.pollEvents();
    }

    // --- RENDER HELPERS ---

    pub const Frame = struct {
        cmd: root.MetalCommandBuffer,
        enc: render.MetalRenderCommandEncoder,
        drawable: objc.Object,

        pub fn submit(self: Frame) void {
            self.enc.endEncoding();
            self.cmd.presentDrawable(self.drawable);
            self.cmd.commit();
        }
    };

    pub fn beginFrame(self: Core, clear_color: render.MTLClearColor) ?Frame {
        const drawable = self.view.nextDrawable() orelse return null;

        // Get Texture from Drawable
        const tex_sel = objc.getSelector("texture");
        const GetTexFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
        const get_tex: GetTexFn = @ptrCast(&objc.objc_msgSend);
        const texture = get_tex(drawable, tex_sel) orelse return null;

        // Create Pass Descriptor
        const pass = render.MetalRenderPassDescriptor.create() orelse return null;
        pass.setColorAttachment(0, texture, .Clear, .Store, clear_color);
        pass.setDepthAttachment(self.depth_texture, 1.0);

        // Create Encoders
        const cmd_buffer = self.queue.createCommandBuffer() orelse return null;
        const encoder = cmd_buffer.createRenderCommandEncoder(pass) orelse return null;

        return Frame{
            .cmd = cmd_buffer,
            .enc = encoder,
            .drawable = drawable,
        };
    }
};
