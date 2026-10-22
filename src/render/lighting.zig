/// GPU-side uniform layout for Blinn-Phong lighting.
/// Must match `LightUniforms` in render/shader.msl.
pub const LightUniforms = extern struct {
    light_pos: [3]f32,
    _pad0: f32 = 0,
    view_pos: [3]f32,
    _pad1: f32 = 0,
    light_color: [3]f32,
    _pad2: f32 = 0,
    ambient_strength: f32,
    specular_strength: f32,
    shininess: f32,
    _pad3: f32 = 0,
};
