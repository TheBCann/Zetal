#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "=== Zetal Engine Refactor ==="
echo "Reorganizing src/ into modular directories..."
echo ""

# Safety: backup
cp -r src src.bak
echo "✓ Backed up src/ → src.bak/"

# 1. Create new directories
mkdir -p src/platform src/ecs src/assets
echo "✓ Created platform/, ecs/, assets/"

# 2. Move files that change location

# platform/
mv src/window.zig src/platform/window.zig
mv src/engine.zig src/platform/engine.zig
echo "✓ Moved window.zig, engine.zig → platform/"

# ecs/
cp src/ecs.zig src/ecs/world.zig
mv src/systems.zig src/ecs/systems.zig
rm src/ecs.zig
echo "✓ Moved ecs.zig → ecs/world.zig, systems.zig → ecs/systems.zig"

# assets/
mv src/loader.zig src/assets/loader.zig
mv src/texture.zig src/assets/texture.zig
echo "✓ Moved loader.zig, texture.zig → assets/"

# 3. Fix import paths in moved files

# platform/window.zig: objc.zig → ../objc.zig
sed -i '' 's|@import("objc.zig")|@import("../objc.zig")|g' src/platform/window.zig
echo "✓ Fixed imports in platform/window.zig"

# platform/engine.zig: needs ../render/, ../objc.zig, and device imports
sed -i '' 's|@import("root.zig")|@import("../render/device.zig")|g' src/platform/engine.zig
sed -i '' 's|@import("render/root.zig")|@import("../render/root.zig")|g' src/platform/engine.zig
sed -i '' 's|@import("objc.zig")|@import("../objc.zig")|g' src/platform/engine.zig
echo "✓ Fixed imports in platform/engine.zig"

# ecs/systems.zig: ecs.zig → world.zig, render paths need ../
sed -i '' 's|@import("ecs.zig")|@import("world.zig")|g' src/ecs/systems.zig
sed -i '' 's|@import("root.zig")|@import("../root.zig")|g' src/ecs/systems.zig
sed -i '' 's|@import("render/root.zig")|@import("../render/root.zig")|g' src/ecs/systems.zig
echo "✓ Fixed imports in ecs/systems.zig"

# assets/loader.zig: render/ → ../render/
sed -i '' 's|@import("render/root.zig")|@import("../render/root.zig")|g' src/assets/loader.zig
sed -i '' 's|@import("root.zig")|@import("../root.zig")|g' src/assets/loader.zig
echo "✓ Fixed imports in assets/loader.zig"

# scene.zig stays at top level but ecs.zig → ecs/world.zig
sed -i '' 's|@import("ecs.zig")|@import("ecs/world.zig")|g' src/scene.zig
echo "✓ Fixed imports in scene.zig"

# 4. Write NEW files

# --- platform/root.zig ---
cat >src/platform/root.zig <<'EOF'
pub const window = @import("window.zig");
pub const engine = @import("engine.zig");
EOF
echo "✓ Created platform/root.zig"

# --- ecs/root.zig ---
cat >src/ecs/root.zig <<'EOF'
pub const world = @import("world.zig");
pub const systems = @import("systems.zig");

// Re-export common types
pub const Entity = world.Entity;
pub const World = world.World;
pub const Transform = world.Transform;
pub const Spin = world.Spin;
pub const Velocity = world.Velocity;
pub const MeshRenderer = world.MeshRenderer;
pub const Collider = world.Collider;
pub const ComponentFlags = world.ComponentFlags;
pub const mask = world.mask;
EOF
echo "✓ Created ecs/root.zig"

# --- assets/root.zig ---
cat >src/assets/root.zig <<'EOF'
pub const loader = @import("loader.zig");
pub const texture = @import("texture.zig");
EOF
echo "✓ Created assets/root.zig"

# --- render/device.zig (Metal wrappers extracted from old root.zig) ---
cat >src/render/device.zig <<'EOF'
const std = @import("std");
const objc = @import("../objc.zig");
const render = @import("root.zig");

extern "Metal" fn MTLCreateSystemDefaultDevice() ?*anyopaque;

// ============================================================
// Metal Types
// ============================================================

pub const MTLSize = extern struct {
    width: u64,
    height: u64,
    depth: u64,
};

pub const MTLOrigin = extern struct {
    x: u64,
    y: u64,
    z: u64,
};

pub const MTLRegion = extern struct {
    origin: MTLOrigin,
    size: MTLSize,
};

pub const MTLResourceOptions = enum(u64) {
    StorageModeShared = 0,
    StorageModePrivate = 2,
};

// ============================================================
// Metal Wrappers
// ============================================================

pub const MetalFunction = struct { handle: objc.Object };
pub const MetalComputePipelineState = struct { handle: objc.Object };

pub const MetalBuffer = struct {
    handle: objc.Object,
    pub fn contents(self: MetalBuffer) *anyopaque {
        const sel = objc.getSelector("contents");
        const Fn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) *anyopaque;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        return msg(self.handle, sel);
    }
};

pub const MetalTexture = struct {
    handle: objc.Object,

    pub fn replaceRegion(self: MetalTexture, region: MTLRegion, bytes: [*]const u8, bytesPerRow: u64) void {
        const sel = objc.getSelector("replaceRegion:mipmapLevel:withBytes:bytesPerRow:");
        const Fn = *const fn (?objc.Object, ?objc.Selector, MTLRegion, u64, [*]const u8, u64) callconv(.c) void;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel, region, 0, bytes, bytesPerRow);
    }
};

pub const MetalComputeCommandEncoder = struct {
    handle: objc.Object,
    pub fn setComputePipelineState(self: MetalComputeCommandEncoder, state: MetalComputePipelineState) void {
        const sel = objc.getSelector("setComputePipelineState:");
        const Fn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) void;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel, state.handle);
    }
    pub fn setBuffer(self: MetalComputeCommandEncoder, buffer: MetalBuffer, offset: u64, index: u64) void {
        const sel = objc.getSelector("setBuffer:offset:atIndex:");
        const Fn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object, u64, u64) callconv(.c) void;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel, buffer.handle, offset, index);
    }
    pub fn dispatchThreadgroups(self: MetalComputeCommandEncoder, groups: MTLSize, threads: MTLSize) void {
        const sel = objc.getSelector("dispatchThreadgroups:threadsPerThreadgroup:");
        const Fn = *const fn (?objc.Object, ?objc.Selector, MTLSize, MTLSize) callconv(.c) void;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel, groups, threads);
    }
    pub fn endEncoding(self: MetalComputeCommandEncoder) void {
        const sel = objc.getSelector("endEncoding");
        _ = objc.objc_msgSend(self.handle, sel);
    }
};

pub const MetalLibrary = struct {
    handle: objc.Object,
    pub fn getFunction(self: MetalLibrary, name: [:0]const u8) ?MetalFunction {
        const ns_name = objc.createNSString(name) orelse return null;
        const sel = objc.getSelector("newFunctionWithName:");
        const Fn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) ?objc.Object;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        if (msg(self.handle, sel, ns_name)) |f| return MetalFunction{ .handle = f };
        return null;
    }
};

pub const MetalCommandBuffer = struct {
    handle: objc.Object,
    pub fn createRenderCommandEncoder(self: MetalCommandBuffer, desc: render.MetalRenderPassDescriptor) ?render.MetalRenderCommandEncoder {
        const sel = objc.getSelector("renderCommandEncoderWithDescriptor:");
        const Fn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) ?objc.Object;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        if (msg(self.handle, sel, desc.handle)) |p| return render.MetalRenderCommandEncoder{ .handle = p };
        return null;
    }
    pub fn presentDrawable(self: MetalCommandBuffer, drawable: objc.Object) void {
        const sel = objc.getSelector("presentDrawable:");
        const Fn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) void;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel, drawable);
    }
    pub fn commit(self: MetalCommandBuffer) void {
        const sel = objc.getSelector("commit");
        _ = objc.objc_msgSend(self.handle, sel);
    }
};

pub const MetalCommandQueue = struct {
    handle: objc.Object,
    pub fn createCommandBuffer(self: MetalCommandQueue) ?MetalCommandBuffer {
        const sel = objc.getSelector("commandBuffer");
        const buf = objc.objc_msgSend(self.handle, sel);
        if (buf) |b| return MetalCommandBuffer{ .handle = b };
        return null;
    }
};

pub const MetalDevice = struct {
    handle: *anyopaque,

    pub fn createSystemDefault() ?MetalDevice {
        const ptr = MTLCreateSystemDefaultDevice();
        if (ptr) |p| return MetalDevice{ .handle = p };
        return null;
    }

    pub fn createCommandQueue(self: MetalDevice) ?MetalCommandQueue {
        const sel = objc.getSelector("newCommandQueue");
        const q = objc.objc_msgSend(self.handle, sel);
        if (q) |ptr| return MetalCommandQueue{ .handle = ptr };
        return null;
    }

    pub fn createLibrary(self: MetalDevice, source: [:0]const u8) ?MetalLibrary {
        const ns_src = objc.createNSString(source) orelse return null;
        const sel = objc.getSelector("newLibraryWithSource:options:error:");
        const Fn = *const fn (?*anyopaque, ?objc.Selector, ?objc.Object, ?*anyopaque, ?*anyopaque) callconv(.c) ?objc.Object;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        if (msg(self.handle, sel, ns_src, null, null)) |l| return MetalLibrary{ .handle = l };
        return null;
    }

    pub fn createRenderPipelineState(self: MetalDevice, desc: render.MetalRenderPipelineDescriptor) ?render.MetalRenderPipeLineState {
        const sel = objc.getSelector("newRenderPipelineStateWithDescriptor:error:");
        const Fn = *const fn (?*anyopaque, ?objc.Selector, ?objc.Object, ?*anyopaque) callconv(.c) ?objc.Object;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        if (msg(self.handle, sel, desc.handle, null)) |p| return render.MetalRenderPipeLineState{ .handle = p };
        return null;
    }

    pub fn createDepthStencilState(self: MetalDevice, desc: render.pipeline.MetalDepthStencilDescriptor) ?render.pipeline.MetalDepthStencilState {
        const sel = objc.getSelector("newDepthStencilStateWithDescriptor:");
        const Fn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) ?objc.Object;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        if (msg(self.handle, sel, desc.handle)) |p| return render.pipeline.MetalDepthStencilState{ .handle = p };
        return null;
    }

    pub fn createBuffer(self: MetalDevice, length: u64, options: MTLResourceOptions) ?MetalBuffer {
        const sel = objc.getSelector("newBufferWithLength:options:");
        const Fn = *const fn (?*anyopaque, ?objc.Selector, u64, u64) callconv(.c) ?objc.Object;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        if (msg(self.handle, sel, length, @intFromEnum(options))) |p| return MetalBuffer{ .handle = p };
        return null;
    }

    pub fn createTexture(self: MetalDevice, width: u64, height: u64, format: u64) ?MetalTexture {
        const desc_class = objc.objc_getClass("MTLTextureDescriptor");
        const desc_sel = objc.getSelector("texture2DDescriptorWithPixelFormat:width:height:mipmapped:");
        const DescFn = *const fn (?objc.Object, ?objc.Selector, u64, u64, u64, bool) callconv(.c) ?objc.Object;
        const desc_msg: DescFn = @ptrCast(&objc.objc_msgSend);
        const tex_desc = desc_msg(desc_class, desc_sel, format, width, height, false);

        const usage_sel = objc.getSelector("setUsage:");
        const UsageFn = *const fn (?objc.Object, ?objc.Selector, u64) callconv(.c) void;
        const usage_msg: UsageFn = @ptrCast(&objc.objc_msgSend);
        usage_msg(tex_desc, usage_sel, 5);

        const newTex_sel = objc.getSelector("newTextureWithDescriptor:");
        const NewTexFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) ?objc.Object;
        const new_tex_msg: NewTexFn = @ptrCast(&objc.objc_msgSend);
        if (new_tex_msg(self.handle, newTex_sel, tex_desc)) |t| return MetalTexture{ .handle = t };
        return null;
    }

    pub fn createDepthTexture(self: MetalDevice, width: u64, height: u64) ?objc.Object {
        const desc_class = objc.objc_getClass("MTLTextureDescriptor");
        const desc_sel = objc.getSelector("texture2DDescriptorWithPixelFormat:width:height:mipmapped:");
        const DescFn = *const fn (?objc.Object, ?objc.Selector, u64, u64, u64, bool) callconv(.c) ?objc.Object;
        const desc_msg: DescFn = @ptrCast(&objc.objc_msgSend);
        const tex_desc = desc_msg(desc_class, desc_sel, 252, width, height, false);

        const usage_sel = objc.getSelector("setUsage:");
        const UsageFn = *const fn (?objc.Object, ?objc.Selector, u64) callconv(.c) void;
        const usage_msg: UsageFn = @ptrCast(&objc.objc_msgSend);
        usage_msg(tex_desc, usage_sel, 4);

        const storage_sel = objc.getSelector("setStorageMode:");
        const StorageFn = *const fn (?objc.Object, ?objc.Selector, u64) callconv(.c) void;
        const storage_msg: StorageFn = @ptrCast(&objc.objc_msgSend);
        storage_msg(tex_desc, storage_sel, 2);

        const newTex_sel = objc.getSelector("newTextureWithDescriptor:");
        const NewTexFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) ?objc.Object;
        const new_tex_msg: NewTexFn = @ptrCast(&objc.objc_msgSend);
        return new_tex_msg(self.handle, newTex_sel, tex_desc);
    }

    /// Like createDepthTexture but with ShaderRead usage so the fragment shader can sample it.
    pub fn createShadowMap(self: MetalDevice, width: u64, height: u64) ?MetalTexture {
        const desc_class = objc.objc_getClass("MTLTextureDescriptor");
        const desc_sel = objc.getSelector("texture2DDescriptorWithPixelFormat:width:height:mipmapped:");
        const DescFn = *const fn (?objc.Object, ?objc.Selector, u64, u64, u64, bool) callconv(.c) ?objc.Object;
        const desc_msg: DescFn = @ptrCast(&objc.objc_msgSend);
        const tex_desc = desc_msg(desc_class, desc_sel, 252, width, height, false);

        const usage_sel = objc.getSelector("setUsage:");
        const UsageFn = *const fn (?objc.Object, ?objc.Selector, u64) callconv(.c) void;
        const usage_msg: UsageFn = @ptrCast(&objc.objc_msgSend);
        usage_msg(tex_desc, usage_sel, 5);

        const storage_sel = objc.getSelector("setStorageMode:");
        const StorageFn = *const fn (?objc.Object, ?objc.Selector, u64) callconv(.c) void;
        const storage_msg: StorageFn = @ptrCast(&objc.objc_msgSend);
        storage_msg(tex_desc, storage_sel, 2); // Private

        const newTex_sel = objc.getSelector("newTextureWithDescriptor:");
        const NewTexFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) ?objc.Object;
        const new_tex_msg: NewTexFn = @ptrCast(&objc.objc_msgSend);
        if (new_tex_msg(self.handle, newTex_sel, tex_desc)) |t| return MetalTexture{ .handle = t };
        return null;
    }
};
EOF
echo "✓ Created render/device.zig"

# --- render/skybox.zig ---
cat >src/render/skybox.zig <<'EOF'
const objc = @import("../objc.zig");
const pipeline = @import("pipeline.zig");
const device = @import("device.zig");

/// Inside-facing cube vertices for skybox (36 verts, position only as float4).
pub const vertices = [36][4]f32{
    // +Z face (looking inward)
    .{ -1, 1, 1, 1 },  .{ -1, -1, 1, 1 }, .{ 1, -1, 1, 1 },
    .{ -1, 1, 1, 1 },  .{ 1, -1, 1, 1 },  .{ 1, 1, 1, 1 },
    // -Z face
    .{ 1, 1, -1, 1 },  .{ 1, -1, -1, 1 }, .{ -1, -1, -1, 1 },
    .{ 1, 1, -1, 1 },  .{ -1, -1, -1, 1 }, .{ -1, 1, -1, 1 },
    // +X face
    .{ 1, 1, 1, 1 },   .{ 1, -1, 1, 1 },  .{ 1, -1, -1, 1 },
    .{ 1, 1, 1, 1 },   .{ 1, -1, -1, 1 }, .{ 1, 1, -1, 1 },
    // -X face
    .{ -1, 1, -1, 1 }, .{ -1, -1, -1, 1 }, .{ -1, -1, 1, 1 },
    .{ -1, 1, -1, 1 }, .{ -1, -1, 1, 1 }, .{ -1, 1, 1, 1 },
    // +Y face (ceiling)
    .{ -1, 1, -1, 1 }, .{ -1, 1, 1, 1 },  .{ 1, 1, 1, 1 },
    .{ -1, 1, -1, 1 }, .{ 1, 1, 1, 1 },   .{ 1, 1, -1, 1 },
    // -Y face (floor)
    .{ -1, -1, 1, 1 }, .{ -1, -1, -1, 1 }, .{ 1, -1, -1, 1 },
    .{ -1, -1, 1, 1 }, .{ 1, -1, -1, 1 }, .{ 1, -1, 1, 1 },
};

pub const vertex_count: u64 = 36;

/// Create a depth stencil state for skybox rendering:
/// depth write OFF, compare LessEqual (skybox z = 1.0 = clear depth).
pub fn createDepthState(dev: device.MetalDevice) ?pipeline.MetalDepthStencilState {
    const desc_class = objc.objc_getClass("MTLDepthStencilDescriptor");
    const alloc_sel = objc.getSelector("alloc");
    const init_sel = objc.getSelector("init");

    const AllocFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
    const alloc_msg: AllocFn = @ptrCast(&objc.objc_msgSend);
    var desc = alloc_msg(desc_class, alloc_sel);

    const InitFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
    const init_msg: InitFn = @ptrCast(&objc.objc_msgSend);
    desc = init_msg(desc, init_sel);

    const cmp_sel = objc.getSelector("setDepthCompareFunction:");
    const CmpFn = *const fn (?*anyopaque, ?*anyopaque, u64) callconv(.c) void;
    const cmp_msg: CmpFn = @ptrCast(&objc.objc_msgSend);
    cmp_msg(desc, cmp_sel, 3); // LessEqual

    const write_sel = objc.getSelector("setDepthWriteEnabled:");
    const WriteFn = *const fn (?*anyopaque, ?*anyopaque, bool) callconv(.c) void;
    const write_msg: WriteFn = @ptrCast(&objc.objc_msgSend);
    write_msg(desc, write_sel, false);

    const new_sel = objc.getSelector("newDepthStencilStateWithDescriptor:");
    const NewFn = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?objc.Object;
    const new_msg: NewFn = @ptrCast(&objc.objc_msgSend);
    if (new_msg(dev.handle, new_sel, desc)) |s| return pipeline.MetalDepthStencilState{ .handle = s };
    return null;
}
EOF
echo "✓ Created render/skybox.zig"

# --- Update render/root.zig ---
cat >src/render/root.zig <<'EOF'
pub const types = @import("types.zig");
pub const pass = @import("pass.zig");
pub const pipeline = @import("pipeline.zig");
pub const vertex = @import("vertex.zig");
pub const shader = @import("shader.zig");
pub const math = @import("math.zig");
pub const device = @import("device.zig");
pub const skybox = @import("skybox.zig");

// Re-export common types
pub const MTLClearColor = types.MTLClearColor;
pub const MTLLoadAction = types.MTLLoadAction;
pub const MTLStoreAction = types.MTLStoreAction;
pub const MetalRenderPassDescriptor = pass.MetalRenderPassDescriptor;
pub const MetalRenderCommandEncoder = pass.MetalRenderCommandEncoder;
pub const MetalRenderPipelineDescriptor = pipeline.MetalRenderPipelineDescriptor;
pub const MetalRenderPipeLineState = pipeline.MetalRenderPipeLineState;

// Re-export device types
pub const MetalDevice = device.MetalDevice;
pub const MetalBuffer = device.MetalBuffer;
pub const MetalTexture = device.MetalTexture;
pub const MetalLibrary = device.MetalLibrary;
pub const MetalCommandBuffer = device.MetalCommandBuffer;
pub const MetalCommandQueue = device.MetalCommandQueue;
pub const MetalFunction = device.MetalFunction;
pub const MTLRegion = device.MTLRegion;
pub const MTLOrigin = device.MTLOrigin;
pub const MTLSize = device.MTLSize;
pub const MTLResourceOptions = device.MTLResourceOptions;
EOF
echo "✓ Updated render/root.zig"

# --- Rewrite src/root.zig (thin module root) ---
cat >src/root.zig <<'EOF'
// ============================================================
// Zetal Engine — Module Root
// ============================================================

pub const objc = @import("objc.zig");
pub const platform = @import("platform/root.zig");
pub const render = @import("render/root.zig");
pub const ecs = @import("ecs/root.zig");
pub const assets = @import("assets/root.zig");
pub const scene = @import("scene.zig");

// --- Convenience re-exports ---
pub const engine = platform.engine;
pub const window = platform.window;
pub const loader = assets.loader;
pub const texture = assets.texture;
pub const systems = ecs.systems;

// --- Device type re-exports ---
pub const MetalDevice = render.device.MetalDevice;
pub const MetalBuffer = render.device.MetalBuffer;
pub const MetalTexture = render.device.MetalTexture;
pub const MetalLibrary = render.device.MetalLibrary;
pub const MetalCommandBuffer = render.device.MetalCommandBuffer;
pub const MetalCommandQueue = render.device.MetalCommandQueue;
pub const MTLRegion = render.device.MTLRegion;
pub const MTLOrigin = render.device.MTLOrigin;
pub const MTLSize = render.device.MTLSize;
pub const MTLResourceOptions = render.device.MTLResourceOptions;

test {
    @import("std").testing.refAllDecls(render.math);
    @import("std").testing.refAllDecls(window);
}
EOF
echo "✓ Rewrote root.zig (thin module root)"

# 5. Done!
echo ""
echo "=== Refactor Complete ==="
echo ""
echo "New structure:"
find src -name '*.zig' -o -name '*.msl' | sort | sed 's|^|  |'
echo ""
echo "Backup in src.bak/"
echo "Run: zig build run"
echo "Restore: rm -rf src && mv src.bak src"
