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
    pixel_w: u64,
    pixel_h: u64,

    const CGSize = extern struct { width: f64, height: f64 };

    pub fn init() !Core {
        const device = root.MetalDevice.createSystemDefault() orelse return error.NoDevice;
        const queue = device.createCommandQueue() orelse return error.NoQueue;
        const app = window.App.init();

        const win = window.Window.create(800, 600, "Zetal Engine") orelse return error.WindowFailed;
        const view = window.MetalView.create(.{ .origin_x = 0, .origin_y = 0, .width = 800, .height = 600 }, device.handle) orelse return error.ViewFailed;
        win.setContentView(view);

        const drawable_size = getDrawableSize(view);
        const pixel_w: u64 = @intFromFloat(drawable_size.width);
        const pixel_h: u64 = @intFromFloat(drawable_size.height);

        const depth_texture = device.createDepthTexture(pixel_w, pixel_h) orelse return error.DepthTextureFailed;

        return Core{
            .device = device,
            .queue = queue,
            .app = app,
            .win = win,
            .view = view,
            .depth_texture = depth_texture,
            .pixel_w = pixel_w,
            .pixel_h = pixel_h,
        };
    }

    fn getDrawableSize(view: window.MetalView) CGSize {
        const size_sel = objc.getSelector("drawableSize");
        const SizeFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) CGSize;
        const size_msg: SizeFn = @ptrCast(&objc.objc_msgSend);
        return size_msg(view.handle, size_sel);
    }

    /// Check if drawable size changed (window resize / fullscreen) and
    /// recreate the depth texture if needed. Returns current aspect ratio.
    pub fn updateSize(self: *Core) f32 {
        const drawable_size = getDrawableSize(self.view);
        const new_w: u64 = @intFromFloat(drawable_size.width);
        const new_h: u64 = @intFromFloat(drawable_size.height);

        if (new_w != self.pixel_w or new_h != self.pixel_h) {
            self.pixel_w = new_w;
            self.pixel_h = new_h;

            // Recreate depth texture at new size
            if (self.device.createDepthTexture(new_w, new_h)) |new_depth| {
                // TODO: release old depth_texture (currently leaks — needs ObjC release call)
                self.depth_texture = new_depth;
            }
        }

        if (self.pixel_h == 0) return 1.0;
        return @as(f32, @floatFromInt(self.pixel_w)) / @as(f32, @floatFromInt(self.pixel_h));
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

        const tex_sel = objc.getSelector("texture");
        const GetTexFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
        const get_tex: GetTexFn = @ptrCast(&objc.objc_msgSend);
        const texture = get_tex(drawable, tex_sel) orelse return null;

        const pass = render.MetalRenderPassDescriptor.create() orelse return null;
        pass.setColorAttachment(0, texture, .Clear, .Store, clear_color);
        pass.setDepthAttachment(self.depth_texture, 1.0);

        const cmd_buffer = self.queue.createCommandBuffer() orelse return null;
        const encoder = cmd_buffer.createRenderCommandEncoder(pass) orelse return null;

        return Frame{
            .cmd = cmd_buffer,
            .enc = encoder,
            .drawable = drawable,
        };
    }
};
