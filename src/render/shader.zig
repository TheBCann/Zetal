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
    \\ struct Uniforms {
    \\     float4x4 modelMatrix;
    \\ };
    \\
    \\ struct VertexOut {
    \\     float4 position [[position]];
    \\     float4 color;
    \\     float2 uv;
    \\     float3 normal;
    \\     float3 worldPos;
    \\ };
    \\
    \\ vertex VertexOut vertex_main(
    \\     uint vertexID [[vertex_id]],
    \\     constant Vertex *vertices [[buffer(0)]],
    \\     constant Uniforms &uniforms [[buffer(1)]]
    \\ ) {
    \\     VertexOut out;
    \\     float4 rawPos = vertices[vertexID].position;
    \\     float4 rawNorm = vertices[vertexID].normal;
    \\
    \\     // Transform position
    \\     out.position = uniforms.modelMatrix * rawPos;
    \\     
    \\     // Rotate the normal (using the upper 3x3 of model matrix)
    \\     // Note: technically should use inverse-transpose, but for pure rotation it's fine
    \\     float3x3 normalMatrix = float3x3(uniforms.modelMatrix[0].xyz, uniforms.modelMatrix[1].xyz, uniforms.modelMatrix[2].xyz);
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
    \\     float3 lightDir = normalize(float3(1.0, 1.0, 1.0)); // Light from top-right-front
    \\     float3 norm = normalize(in.normal);
    \\     
    \\     // Diffuse: max(dot(N, L), 0.0)
    \\     float diff = max(dot(norm, lightDir), 0.0);
    \\     
    \\     // Ambient: minimum light so shadows aren't pitch black
    \\     float ambient = 0.3;
    \\     
    \\     // Combine
    \\     float3 finalLight = (diff + ambient) * in.color.rgb;
    \\     
    \\     return float4(finalLight * texColor.rgb, 1.0);
    \\ }
;
