pub const triangle_source =
    \\ #include <metal_stdlib>
    \\ using namespace metal;
    \\
    \\ struct Vertex {
    \\     float4 position;
    \\     float4 color;
    \\     float4 uv; // Changed to float4 to match 16-byte alignment
    \\ };
    \\
    \\ struct Uniforms {
    \\     float4x4 modelMatrix;
    \\ };
    \\
    \\ struct VertexOut {
    \\     float4 position [[position]];
    \\     float4 color;
    \\     float2 uv;
    \\ };
    \\
    \\ vertex VertexOut vertex_main(
    \\     uint vertexID [[vertex_id]],
    \\     constant Vertex *vertices [[buffer(0)]],
    \\     constant Uniforms &uniforms [[buffer(1)]]
    \\ ) {
    \\     VertexOut out;
    \\     float4 rawPos = vertices[vertexID].position;
    \\     out.position = uniforms.modelMatrix * rawPos;
    \\     out.color = vertices[vertexID].color;
    \\     out.uv = vertices[vertexID].uv.xy; // Use only XY
    \\     return out;
    \\ }
    \\
    \\ fragment float4 fragment_main(
    \\     VertexOut in [[stage_in]],
    \\     texture2d<float> tex [[texture(0)]]
    \\ ) {
    \\     constexpr sampler sam(mag_filter::nearest, min_filter::nearest, address::repeat);
    \\     float4 texColor = tex.sample(sam, in.uv);
    \\     return texColor * in.color;
    \\ }
;
