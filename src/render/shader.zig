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
    \\     float4 lightSpacePos;
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
    \\ // ===========================================
    \\ // SHADOW PASS — depth only from light's POV
    \\ // ===========================================
    \\
    \\ struct ShadowOut {
    \\     float4 position [[position]];
    \\ };
    \\
    \\ // Shadow pass for instanced objects (cubes)
    \\ vertex ShadowOut shadow_vertex(
    \\     uint vertexID [[vertex_id]],
    \\     uint instanceID [[instance_id]],
    \\     constant Vertex *vertices [[buffer(0)]],
    \\     constant float4x4 *lightMVPs [[buffer(1)]]
    \\ ) {
    \\     ShadowOut out;
    \\     out.position = lightMVPs[instanceID] * vertices[vertexID].position;
    \\     return out;
    \\ }
    \\
    \\ // Shadow pass for single objects (ground)
    \\ vertex ShadowOut shadow_vertex_single(
    \\     uint vertexID [[vertex_id]],
    \\     constant Vertex *vertices [[buffer(0)]],
    \\     constant float4x4 &lightMVP [[buffer(1)]]
    \\ ) {
    \\     ShadowOut out;
    \\     out.position = lightMVP * vertices[vertexID].position;
    \\     return out;
    \\ }
    \\
    \\ // ===========================================
    \\ // MAIN PASS — instanced vertex shader
    \\ // ===========================================
    \\
    \\ vertex VertexOut vertex_main(
    \\     uint vertexID [[vertex_id]],
    \\     uint instanceID [[instance_id]],
    \\     constant Vertex *vertices [[buffer(0)]],
    \\     constant float4x4 *mvps [[buffer(1)]],
    \\     constant float4x4 *models [[buffer(3)]],
    \\     constant float4x4 &lightVP [[buffer(4)]]
    \\ ) {
    \\     VertexOut out;
    \\     float4x4 mvp = mvps[instanceID];
    \\     float4x4 model = models[instanceID];
    \\     float4 rawPos = vertices[vertexID].position;
    \\     float4 rawNorm = vertices[vertexID].normal;
    \\
    \\     out.position = mvp * rawPos;
    \\     out.worldPos = (model * rawPos).xyz;
    \\     out.lightSpacePos = lightVP * model * rawPos;
    \\
    \\     float3x3 normalMatrix = float3x3(model[0].xyz, model[1].xyz, model[2].xyz);
    \\     out.normal = normalize(normalMatrix * rawNorm.xyz);
    \\
    \\     out.color = vertices[vertexID].color;
    \\     out.uv = vertices[vertexID].uv.xy;
    \\     return out;
    \\ }
    \\
    \\ // ===========================================
    \\ // MAIN PASS — single object vertex shader
    \\ // ===========================================
    \\
    \\ vertex VertexOut vertex_single(
    \\     uint vertexID [[vertex_id]],
    \\     constant Vertex *vertices [[buffer(0)]],
    \\     constant float4x4 &mvp [[buffer(1)]],
    \\     constant float4x4 &model [[buffer(3)]],
    \\     constant float4x4 &lightVP [[buffer(4)]]
    \\ ) {
    \\     VertexOut out;
    \\     float4 rawPos = vertices[vertexID].position;
    \\     float4 rawNorm = vertices[vertexID].normal;
    \\
    \\     out.position = mvp * rawPos;
    \\     out.worldPos = (model * rawPos).xyz;
    \\     out.lightSpacePos = lightVP * model * rawPos;
    \\
    \\     float3x3 normalMatrix = float3x3(model[0].xyz, model[1].xyz, model[2].xyz);
    \\     out.normal = normalize(normalMatrix * rawNorm.xyz);
    \\
    \\     out.color = vertices[vertexID].color;
    \\     out.uv = vertices[vertexID].uv.xy;
    \\     return out;
    \\ }
    \\
    \\ // ===========================================
    \\ // BLINN-PHONG + SHADOW FRAGMENT SHADER
    \\ // ===========================================
    \\
    \\ float shadowCalc(float4 lightSpacePos, depth2d<float> shadowMap) {
    \\     // Perspective divide (orthographic: w=1, but good practice)
    \\     float3 projCoords = lightSpacePos.xyz / lightSpacePos.w;
    \\
    \\     // Transform from NDC [-1,1] to texture coords [0,1]
    \\     // Metal NDC: x,y in [-1,1], z in [0,1]
    \\     float2 shadowUV = projCoords.xy * 0.5 + 0.5;
    \\     shadowUV.y = 1.0 - shadowUV.y; // Flip Y for Metal texture coords
    \\
    \\     // Outside shadow map — not in shadow
    \\     if (shadowUV.x < 0.0 || shadowUV.x > 1.0 || shadowUV.y < 0.0 || shadowUV.y > 1.0) {
    \\         return 0.0;
    \\     }
    \\
    \\     float currentDepth = projCoords.z;
    \\
    \\     // PCF (percentage-closer filtering) 3x3
    \\     constexpr sampler shadowSampler(coord::normalized, filter::linear, address::clamp_to_edge, compare_func::less);
    \\     float shadow = 0.0;
    \\     float bias = 0.005;
    \\     float texelSize = 1.0 / 2048.0;
    \\
    \\     for (int x = -1; x <= 1; x++) {
    \\         for (int y = -1; y <= 1; y++) {
    \\             float2 offset = float2(float(x), float(y)) * texelSize;
    \\             float pcfDepth = shadowMap.sample(shadowSampler, shadowUV + offset);
    \\             shadow += (currentDepth - bias > pcfDepth) ? 1.0 : 0.0;
    \\         }
    \\     }
    \\     shadow /= 9.0;
    \\
    \\     return shadow;
    \\ }
    \\
    \\ fragment float4 fragment_main(
    \\     VertexOut in [[stage_in]],
    \\     texture2d<float> tex [[texture(0)]],
    \\     depth2d<float> shadowMap [[texture(1)]],
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
    \\     // Specular (Blinn-Phong)
    \\     float3 halfDir = normalize(lightDir + viewDir);
    \\     float spec = pow(max(dot(norm, halfDir), 0.0), light.shininess);
    \\     float3 specular = light.specularStrength * spec * light.lightColor;
    \\
    \\     // Shadow
    \\     float shadow = shadowCalc(in.lightSpacePos, shadowMap);
    \\
    \\     // Combine: ambient always visible, diffuse+specular reduced by shadow
    \\     float3 result = (ambient + (1.0 - shadow) * (diffuse + specular)) * in.color.rgb * texColor.rgb;
    \\     return float4(result, 1.0);
    \\ }
;
