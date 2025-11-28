#version 450 core
#extension GL_ARB_separate_shader_objects : enable

#define CLIPMAP_LEVEL_COUNT 9

layout(location = 0) in vec3 vWorldPos;
layout(location = 1) in vec3 vNormal;
layout(location = 2) in vec2 vClipmapUV;
layout(location = 3) in vec2 vParentClipmapUV;
layout(location = 4) in float vMorphFactor;
layout(location = 5) flat in int vLevelIndex;
layout(location = 6) flat in int vParentLevelIndex;

layout(location = 0) out vec4 FragColor;

struct ClipmapCameraUniform
{
    mat4 viewMatrix;
    mat4 projectionMatrix;
    mat4 viewProjectionMatrix;
    vec4 cameraWorldPosition;
};

struct ClipmapLevelUniform
{
    vec4 worldOriginAndSpacing;
    vec4 textureInfo;
    vec4 torusParams;
};

layout(binding = 0) uniform ClipmapUniforms
{
    ClipmapCameraUniform camera;
    ClipmapLevelUniform levels[CLIPMAP_LEVEL_COUNT];
} uClipmap;

layout(binding = 2) uniform sampler2D diffuseClipmaps[CLIPMAP_LEVEL_COUNT];
layout(binding = 3) uniform sampler2D normalClipmaps[CLIPMAP_LEVEL_COUNT];

const vec3 lightDirection = normalize(vec3(0.35, 1.0, 0.25));
const vec3 ambientColor  = vec3(0.26);

// -----------------------------
// Hash / noise helpers
// -----------------------------

// Simple 2D hash to [0,1]
float hash12(vec2 p)
{
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Hash to vec2 in [0,1]^2
vec2 hash22(vec2 p)
{
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

// Cheap value noise
float valueNoise(vec2 p)
{
    vec2 i = floor(p);
    vec2 f = fract(p);

    float a = hash12(i);
    float b = hash12(i + vec2(1.0, 0.0));
    float c = hash12(i + vec2(0.0, 1.0));
    float d = hash12(i + vec2(1.0, 1.0));

    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u.x) +
           (c - a) * u.y * (1.0 - u.x) +
           (d - b) * u.x * u.y;
}

float fbm(vec2 p)
{
    float amplitude = 0.5;
    float frequency = 1.0;
    float sum = 0.0;

    for (int i = 0; i < 5; ++i)
    {
        sum += amplitude * valueNoise(p * frequency);
        frequency *= 2.0;
        amplitude *= 0.5;
    }
    return sum;
}

// -----------------------------
// Rugged Earth terrain
// -----------------------------

// Ridged noise variant for sharp peaks.
float ridgeNoise(vec2 p)
{
    float n = valueNoise(p) * 2.0 - 1.0;
    n = 1.0 - abs(n);
    return n * n;
}

// Ridged fractal Brownian motion for mountains.
float ridgedFBM(vec2 p)
{
    float sum = 0.0;
    float amplitude = 0.72;
    float frequency = 0.55;
    float weight = 0.9;

    for (int i = 0; i < 6; ++i)
    {
        float n = ridgeNoise(p * frequency);
        n *= weight;

        sum += n * amplitude;

        weight = clamp(n * 1.25, 0.0, 1.0);
        frequency *= 1.9;
        amplitude *= 0.5;
    }

    return sum;
}

// Full rugged Earth-style height field used for shading only.
float ruggedHeight(vec2 worldXZ)
{
    // Map world coordinates to a compact domain for mountainous detail.
    const float domainScale = 0.0022;
    vec2 p = worldXZ * domainScale;

    float h = 0.0;

    // Broad mountain ranges with slightly stronger relief.
    h += ridgedFBM(p * 0.85) * 0.95;

    // Valleys and plateaus with extra breakup for ridgeline variety.
    h += (fbm(p * 0.55) - 0.5) * 0.32;

    // Rocky roughness.
    h += (ridgeNoise(p * 7.5) - 0.35) * 0.16;

    // Fine craggy detail to keep silhouettes from looking smooth.
    h += (fbm(p * 12.0) - 0.5) * 0.08;

    return h;
}

// Compute a micro normal from the procedural height field, then blend
// it with the macro normal coming from the geometry / normal maps.
vec3 computeRuggedNormal(vec3 macroNormal, vec2 worldXZ)
{
    const float eps = 0.0035;

    float hC = ruggedHeight(worldXZ);
    float hX = ruggedHeight(worldXZ + vec2(eps, 0.0));
    float hZ = ruggedHeight(worldXZ + vec2(0.0, eps));

    vec3 dx = vec3(eps, hX - hC, 0.0);
    vec3 dz = vec3(0.0, hZ - hC, eps);
    vec3 n  = normalize(cross(dz, dx));

    // Blend micro and macro normals; lean a bit more on the macro normal
    // to soften small-scale ruggedness.
    return normalize(mix(macroNormal, n, 0.45));
}

// Snow accumulation mask based on slope, elevation, windward exposure, and noisy breakup.
float computeSnowCoverage(vec3 macroNormal, vec2 worldXZ, float heightSample)
{
    float slope = 1.0 - clamp(dot(macroNormal, vec3(0.0, 1.0, 0.0)), 0.0, 1.0);
    float elevation = clamp(heightSample * 1.8, -1.0, 1.5);

    // Base snow from elevation and surface flatness.
    float baseSnow = smoothstep(0.55, 0.85, elevation);
    float flatness = 1.0 - smoothstep(0.2, 0.65, slope);

    // Wind-blown drift bias; surfaces facing the wind accumulate more.
    vec2 windDir = normalize(vec2(0.65, 0.35));
    vec2 surfaceDir = normalize(vec2(macroNormal.x, macroNormal.z) + 1e-4);
    float drift = clamp(dot(windDir, surfaceDir) * 0.5 + 0.5, 0.0, 1.0);

    // Breakup to avoid uniform coverage and to reveal underlying rock in streaks.
    float pocketNoise = smoothstep(0.25, 0.8, fbm(worldXZ * 0.045 + vec2(4.2, -3.1)));
    float crustNoise  = smoothstep(0.35, 0.75, fbm(worldXZ * 0.12 - vec2(2.7, 1.9)));

    float coverage = baseSnow * flatness;
    coverage *= mix(0.6, 1.0, pocketNoise);
    coverage = mix(coverage * 0.85, coverage, drift);
    coverage *= (0.8 + crustNoise * 0.2);

    return clamp(coverage, 0.0, 1.0);
}

// Earthy albedo based on slope and elevation, tinted by existing clipmaps.
vec3 computeRuggedAlbedo(vec3 baseAlbedo, vec3 macroNormal, vec2 worldXZ, float heightSample, float snowCoverage)
{
    float slope = 1.0 - clamp(dot(macroNormal, vec3(0.0, 1.0, 0.0)), 0.0, 1.0);
    float elevation = clamp(heightSample * 1.8, -1.0, 1.5);

    vec3 grass = vec3(0.16, 0.30, 0.13);
    vec3 rock  = vec3(0.40, 0.37, 0.32);
    vec3 snow  = vec3(0.88, 0.90, 0.93);

    // Slope mask: steeper surfaces get more rock, flatter ones more vegetation.
    float rockMask = smoothstep(0.25, 0.55, slope);

    // Elevation mask: higher altitudes transition to snow.
    float snowMask = smoothstep(0.55, 0.85, elevation);

    // Snow sits more readily on flatter ground and collects in noisy pockets.
    // Use increasing edge values to avoid undefined smoothstep behavior on some GPUs.
    const float slopeSnowMin = 0.25;
    const float slopeSnowMax = 0.6;
    float slopeSnowAttenuation = smoothstep(slopeSnowMin, slopeSnowMax, slope);
    snowCoverage *= slopeSnowAttenuation;

    // Subtle color variation for soil/vegetation patches.
    float soilNoise = fbm(worldXZ * 0.015);
    vec3 soilTint = mix(vec3(0.22, 0.18, 0.12), grass, soilNoise);

    vec3 terrainBase = mix(soilTint, rock, rockMask);

    // Snow inherits some of the underlying vegetation hue so the transition isn't pure white.
    vec3 snowColor = snow + vec3(0.02, 0.03, 0.06) * (fbm(worldXZ * 0.02) - 0.5);
    vec3 snowBlendedWithVegetation = mix(snowColor, soilTint, 0.22);
    terrainBase = mix(terrainBase, snowBlendedWithVegetation, snowCoverage);

    // Blend with incoming albedo so existing textures still influence the look.
    vec3 mixedAlbedo = mix(baseAlbedo, terrainBase, 0.6);
    mixedAlbedo *= 0.95 + 0.15 * (fbm(worldXZ * 0.06) - 0.5);

    return mixedAlbedo;
}

// -----------------------------
// Main
// -----------------------------
void main()
{
    if (vLevelIndex < 0 || vLevelIndex >= CLIPMAP_LEVEL_COUNT ||
        vParentLevelIndex < 0 || vParentLevelIndex >= CLIPMAP_LEVEL_COUNT)
    {
        discard;
    }

    // Clipmap sampling (macro features from your existing textures).
    vec3 albedo0 = texture(diffuseClipmaps[vLevelIndex],       vClipmapUV).rgb;
    vec3 albedo1 = texture(diffuseClipmaps[vParentLevelIndex], vParentClipmapUV).rgb;
    vec3 albedo  = mix(albedo0, albedo1, vMorphFactor);

    vec3 normal0 = texture(normalClipmaps[vLevelIndex],       vClipmapUV).rgb * 2.0 - 1.0;
    vec3 normal1 = texture(normalClipmaps[vParentLevelIndex], vParentClipmapUV).rgb * 2.0 - 1.0;
    vec3 normalSample = normalize(mix(normal0, normal1, vMorphFactor));
    vec3 macroNormal  = normalize(vNormal + normalSample * 0.35);

    // Procedural rugged terrain height and micro normal.
    vec2 worldXZ = vWorldPos.xz;
    float h = ruggedHeight(worldXZ);
    float snowCoverage = computeSnowCoverage(macroNormal, worldXZ, h);
    vec3 ruggedNormal = computeRuggedNormal(macroNormal, worldXZ);
    ruggedNormal = normalize(mix(ruggedNormal, vec3(0.0, 1.0, 0.0), snowCoverage * 0.35));

    // Terrain albedo derived from your clipmaps + procedural detail.
    vec3 terrainAlbedo = computeRuggedAlbedo(albedo, macroNormal, worldXZ, h, snowCoverage);

    // Lighting: strong directional "sun" + soft ambient.
    vec3 L = normalize(lightDirection);
    vec3 N = normalize(ruggedNormal);

    vec3 viewDir = uClipmap.camera.cameraWorldPosition.xyz - vWorldPos;
    float viewLen = max(length(viewDir), 1e-4);
    vec3 V = viewDir / viewLen;

    float NdotL = max(dot(N, L), 0.0);
    float NdotV = max(dot(N, V), 0.0);

    vec3 diffuse = terrainAlbedo * NdotL;

    // Subtle rim light to accent crater rims when looking toward the light.
    float rim = pow(1.0 - NdotV, 3.0);
    vec3 rimLight = terrainAlbedo * rim * 0.25;

    // Sparkly specular highlights on fresh snow.
    vec3 H = normalize(L + V);
    float specPower = mix(6.0, 48.0, snowCoverage);
    float specular = pow(max(dot(N, H), 0.0), specPower) * snowCoverage;
    vec3 specularColor = mix(vec3(0.08), vec3(0.9, 0.95, 1.05), snowCoverage) * specular;

    // Slightly brighter ambient bounce for snow.
    float snowAmbientBoost = mix(1.0, 1.25, snowCoverage);
    vec3 ambient = ambientColor * terrainAlbedo * snowAmbientBoost;

    vec3 color = ambient + diffuse + rimLight + specularColor;
    color = max(color, vec3(0.03));

    FragColor = vec4(color, 1.0);
}
