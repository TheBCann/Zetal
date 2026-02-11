pub const triangle_source =
    \\ #include <metal_stdlib>
    \\ using namespace metal;
    \\
    \\ struct Vertex {
    \\     float4 position;
    \\     float4 color;
    \\     float4 uv;
    \\     float4 normal;
    \\ };
    \\
    \\ struct VertexOut {
    \\     float4 position [[position]];
    \\     float4 color;
    \\     float2 uv;
    \\     float3 normal;
    \\ };
    \\
    \\ vertex VertexOut vertex_main(
    \\     uint vertexID [[vertex_id]],
    \\     uint instanceID [[instance_id]],
    \\     constant Vertex *vertices [[buffer(0)]],
    \\     constant float4x4 *mvps [[buffer(1)]]
    \\ ) {
    \\     VertexOut out;
    \\     float4x4 mvp = mvps[instanceID];
    \\     float4 rawPos = vertices[vertexID].position;
    \\     float4 rawNorm = vertices[vertexID].normal;
    \\
    \\     out.position = mvp * rawPos;
    \\
    \\     // Rotate normal (upper 3x3 of the MVP - approximate)
    \\     float3x3 normalMatrix = float3x3(mvp[0].xyz, mvp[1].xyz, mvp[2].xyz);
    \\     out.normal = normalMatrix * rawNorm.xyz;
    \\
    \\     out.color = vertices[vertexID].color;
    \\     out.uv = vertices[vertexID].uv.xy;
    \\     return out;
    \\ }
    \\
    \\ fragment float4 fragment_main(
    \\     VertexOut in [[stage_in]],
    \\     texture2d<float> tex [[texture(0)]]
    \\ ) {
    \\     constexpr sampler sam(mag_filter::nearest, min_filter::nearest, address::repeat);
    \\     float4 texColor = tex.sample(sam, in.uv);
    \\
    \\     // --- LIGHTING ---
    \\     float3 lightDir = normalize(float3(1.0, 1.0, 1.0));
    \\     float3 norm = normalize(in.normal);
    \\
    \\     float diff = max(dot(norm, lightDir), 0.0);
    \\     float ambient = 0.3;
    \\     float3 finalLight = (diff + ambient) * in.color.rgb;
    \\
    \\     return float4(finalLight * texColor.rgb, 1.0);
    \\ }
;
