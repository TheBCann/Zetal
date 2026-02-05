pub const triangle_source =
    \\ #include <metal_stdlib>
    \\ using namespace metal;
    \\
    \\ struct Vertex {
    \\     float4 position;
    \\     float4 color;
    \\ };
    \\
    \\ struct VertexOut {
    \\     float4 position [[position]];
    \\     float4 color;
    \\ };
    \\
    \\ vertex VertexOut vertex_main(
    \\     uint vertexID [[vertex_id]],
    \\     constant Vertex *vertices [[buffer(0)]]
    \\ ) {
    \\     VertexOut out;
    \\     // Direct array indexing - simple and robust
    \\     out.position = vertices[vertexID].position;
    \\     out.color = vertices[vertexID].color;
    \\     return out;
    \\ }
    \\
    \\ fragment float4 fragment_main(VertexOut in [[stage_in]]) {
    \\     return in.color;
    \\ }
;
