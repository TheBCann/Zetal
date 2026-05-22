const device = @import("device.zig");
const pipeline = @import("pipeline.zig");
const shader = @import("shader.zig");
const crosshair = @import("crosshair.zig");

const RenderPipelineState = pipeline.MetalRenderPipelineState;
const DepthStencilState = pipeline.MetalDepthStencilState;
const PipelineDescriptor = pipeline.MetalRenderPipelineDescriptor;
const DepthDescriptor = pipeline.MetalDepthStencilDescriptor;

pub const Pipelines = struct {
    cube: RenderPipelineState,
    ground: RenderPipelineState,
    shadow: RenderPipelineState,
    shadow_ground: RenderPipelineState,
    sky: RenderPipelineState,
    crosshair: RenderPipelineState,

    depth: DepthStencilState,
    sky_depth: DepthStencilState,
    crosshair_depth: DepthStencilState,
    viewmodel_depth: DepthStencilState,

    pub fn init(dev: device.MetalDevice) !Pipelines {
        const lib = dev.createLibrary(shader.triangle_source) orelse return error.LibraryFailed;
        const ch_lib = dev.createLibrary(crosshair.crosshair_source) orelse return error.LibraryFailed;

        const cube_pipe = try buildPipeline(dev, lib, "vertex_main", "fragment_main", true);
        const ground_pipe = try buildPipeline(dev, lib, "vertex_single", "fragment_main", true);
        const sky_pipe = try buildPipeline(dev, lib, "skybox_vertex", "skybox_fragment", true);
        const shadow_pipe = try buildShadowPipeline(dev, lib, "shadow_vertex");
        const shadow_ground_pipe = try buildShadowPipeline(dev, lib, "shadow_vertex_single");
        const ch_pipe = try buildPipeline(dev, ch_lib, "crosshair_vertex", "crosshair_fragment", true);

        return Pipelines{
            .cube = cube_pipe,
            .ground = ground_pipe,
            .shadow = shadow_pipe,
            .shadow_ground = shadow_ground_pipe,
            .sky = sky_pipe,
            .crosshair = ch_pipe,
            .depth = try buildDepth(dev, .less, true),
            .sky_depth = try buildDepth(dev, .less_equal, false),
            .crosshair_depth = try buildDepth(dev, .always, false),
            .viewmodel_depth = try buildDepth(dev, .always, true),
        };
    }
};

fn buildPipeline(
    dev: device.MetalDevice,
    lib: device.MetalLibrary,
    vertex_fn: [:0]const u8,
    fragment_fn: [:0]const u8,
    has_color: bool,
) !RenderPipelineState {
    const desc = PipelineDescriptor.create() orelse return error.PipelineDescFailed;
    const vf = lib.getFunction(vertex_fn) orelse return error.VertexFunctionMissing;
    const ff = lib.getFunction(fragment_fn) orelse return error.FragmentFunctionMissing;
    desc.setVertexFunction(vf.handle);
    desc.setFragmentFunction(ff.handle);
    if (has_color) desc.setColorAttachmentPixelFormat(0, .bgra8_unorm);
    desc.setDepthAttachmentPixelFormat(.depth32_float);
    return dev.createRenderPipelineState(desc) orelse error.PipelineFailed;
}

fn buildShadowPipeline(
    dev: device.MetalDevice,
    lib: device.MetalLibrary,
    vertex_fn: [:0]const u8,
) !RenderPipelineState {
    const desc = PipelineDescriptor.create() orelse return error.PipelineDescFailed;
    const vf = lib.getFunction(vertex_fn) orelse return error.VertexFunctionMissing;
    desc.setVertexFunction(vf.handle);
    desc.setDepthAttachmentPixelFormat(.depth32_float);
    return dev.createRenderPipelineState(desc) orelse error.PipelineFailed;
}

fn buildDepth(
    dev: device.MetalDevice,
    compare: @import("types.zig").MTLCompareFunction,
    write: bool,
) !DepthStencilState {
    const desc = DepthDescriptor.create() orelse return error.DepthDescFailed;
    desc.setDepthCompareFunction(compare);
    desc.setDepthWriteEnabled(write);
    return dev.createDepthStencilState(desc) orelse error.DepthStateFailed;
}
