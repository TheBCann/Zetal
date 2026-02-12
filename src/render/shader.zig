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
    \\     float3 worldPos;
    \\ };
    \\
    \\ struct LightUniforms {
    \\     float3 lightPos;
    \\     float3 viewPos;
    \\     float3 lightColor;
    \\     float ambientStrength;
    \\     float specularStrength;
    \\     float shininess;
    \\ };
    \\
    \\ // --- INSTANCED VERTEX SHADER (cubes) ---
    \\ vertex VertexOut vertex_main(
    \\     uint vertexID [[vertex_id]],
    \\     uint instanceID [[instance_id]],
    \\     constant Vertex *vertices [[buffer(0)]],
    \\     constant float4x4 *mvps [[buffer(1)]],
    \\     constant float4x4 *models [[buffer(3)]]
    \\ ) {
    \\     VertexOut out;
    \\     float4x4 mvp = mvps[instanceID];
    \\     float4x4 model = models[instanceID];
    \\     float4 rawPos = vertices[vertexID].position;
    \\     float4 rawNorm = vertices[vertexID].normal;
    \\
    \\     out.position = mvp * rawPos;
    \\     out.worldPos = (model * rawPos).xyz;
    \\
    \\     // Transform normal by model matrix (upper 3x3)
    \\     float3x3 normalMatrix = float3x3(model[0].xyz, model[1].xyz, model[2].xyz);
    \\     out.normal = normalize(normalMatrix * rawNorm.xyz);
    \\
    \\     out.color = vertices[vertexID].color;
    \\     out.uv = vertices[vertexID].uv.xy;
    \\     return out;
    \\ }
    \\
    \\ // --- SINGLE-OBJECT VERTEX SHADER (ground plane) ---
    \\ vertex VertexOut vertex_single(
    \\     uint vertexID [[vertex_id]],
    \\     constant Vertex *vertices [[buffer(0)]],
    \\     constant float4x4 &mvp [[buffer(1)]],
    \\     constant float4x4 &model [[buffer(3)]]
    \\ ) {
    \\     VertexOut out;
    \\     float4 rawPos = vertices[vertexID].position;
    \\     float4 rawNorm = vertices[vertexID].normal;
    \\
    \\     out.position = mvp * rawPos;
    \\     out.worldPos = (model * rawPos).xyz;
    \\
    \\     float3x3 normalMatrix = float3x3(model[0].xyz, model[1].xyz, model[2].xyz);
    \\     out.normal = normalize(normalMatrix * rawNorm.xyz);
    \\
    \\     out.color = vertices[vertexID].color;
    \\     out.uv = vertices[vertexID].uv.xy;
    \\     return out;
    \\ }
    \\
    \\ // --- BLINN-PHONG FRAGMENT SHADER (shared) ---
    \\ fragment float4 fragment_main(
    \\     VertexOut in [[stage_in]],
    \\     texture2d<float> tex [[texture(0)]],
    \\     constant LightUniforms &light [[buffer(2)]]
    \\ ) {
    \\     constexpr sampler sam(mag_filter::nearest, min_filter::nearest, address::repeat);
    \\     float4 texColor = tex.sample(sam, in.uv);
    \\
    \\     float3 norm = normalize(in.normal);
    \\     float3 lightDir = normalize(light.lightPos - in.worldPos);
    \\     float3 viewDir = normalize(light.viewPos - in.worldPos);
    \\
    \\     // Ambient
    \\     float3 ambient = light.ambientStrength * light.lightColor;
    \\
    \\     // Diffuse
    \\     float diff = max(dot(norm, lightDir), 0.0);
    \\     float3 diffuse = diff * light.lightColor;
    \\
    \\     // Specular (Blinn-Phong: half-vector)
    \\     float3 halfDir = normalize(lightDir + viewDir);
    \\     float spec = pow(max(dot(norm, halfDir), 0.0), light.shininess);
    \\     float3 specular = light.specularStrength * spec * light.lightColor;
    \\
    \\     float3 result = (ambient + diffuse + specular) * in.color.rgb * texColor.rgb;
    \\     return float4(result, 1.0);
    \\ }
;
