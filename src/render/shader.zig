pub const triangle_source =
    \\ #include <metal_stdlib>
    \\ using namespace metal;
    \\
    \\ struct Vertex {
    \\     float4 position;
    \\     float4 color;
    \\ };
    \\
    \\ struct Uniforms {
    \\     float4x4 modelMatrix;
    \\ };
    \\
    \\ struct VertexOut {
    \\     float4 position [[position]];
    \\     float4 color;
    \\ };
    \\
    \\ vertex VertexOut vertex_main(
    \\     uint vertexID [[vertex_id]],
    \\     constant Vertex *vertices [[buffer(0)]],
    \\     constant Uniforms &uniforms [[buffer(1)]]  // NEW: Buffer Index 1
    \\ ) {
    \\     VertexOut out;
    \\     
    \\     // 1. Get the raw position
    \\     float4 rawPos = vertices[vertexID].position;
    \\
    \\     // 2. Multiply by the rotation matrix
    \\     out.position = uniforms.modelMatrix * rawPos;
    \\
    \\     out.color = vertices[vertexID].color;
    \\     return out;
    \\ }
    \\
    \\ fragment float4 fragment_main(VertexOut in [[stage_in]]) {
    \\     return in.color;
    \\ }
;
