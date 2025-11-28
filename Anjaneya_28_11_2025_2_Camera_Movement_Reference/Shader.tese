#version 450 core
#extension GL_ARB_separate_shader_objects : enable

#define CLIPMAP_LEVEL_COUNT 9

layout(triangles, equal_spacing, cw) in;

#define CLIPMAP_SKIRT_DEPTH 12.0

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

layout(location = 0) in vec2 tcGridCoord[];
layout(location = 1) in vec2 tcEdgeDir[];

layout(location = 0) out vec3 vWorldPos;
layout(location = 1) out vec3 vNormal;
layout(location = 2) out vec2 vClipmapUV;
layout(location = 3) out vec2 vParentClipmapUV;
layout(location = 4) out float vMorphFactor;
layout(location = 5) flat out int vLevelIndex;
layout(location = 6) flat out int vParentLevelIndex;

layout(binding = 0) uniform ClipmapUniforms
{
    ClipmapCameraUniform camera;
    ClipmapLevelUniform levels[CLIPMAP_LEVEL_COUNT];
} uClipmap;

layout(binding = 1) uniform sampler2D heightClipmaps[CLIPMAP_LEVEL_COUNT];

layout(push_constant) uniform PushConstants
{
    int levelIndex;
    int patchType;
    int pad0;
    int pad1;
} uPush;

vec2 WrapClipmapTexCoord(vec2 coord)
{
    return fract(coord);
}

vec2 ComputeClipmapTexCoord(ClipmapLevelUniform level, vec2 gridCoord)
{
    vec2 clamped = clamp(gridCoord, vec2(0.0), vec2(level.torusParams.z));
    vec2 normalized = (clamped + level.torusParams.xy) * level.textureInfo.x;
    normalized.y = 1.0 - normalized.y;
    return WrapClipmapTexCoord(normalized);
}

vec3 ComputeNormal(int samplerIndex, ClipmapLevelUniform level, vec2 texCoord)
{
    vec2 texelOffsetX = vec2(level.textureInfo.x, 0.0);
    vec2 texelOffsetY = vec2(0.0, level.textureInfo.x);

    float hL = texture(heightClipmaps[samplerIndex], WrapClipmapTexCoord(texCoord - texelOffsetX)).r * level.textureInfo.y;
    float hR = texture(heightClipmaps[samplerIndex], WrapClipmapTexCoord(texCoord + texelOffsetX)).r * level.textureInfo.y;
    float hD = texture(heightClipmaps[samplerIndex], WrapClipmapTexCoord(texCoord - texelOffsetY)).r * level.textureInfo.y;
    float hU = texture(heightClipmaps[samplerIndex], WrapClipmapTexCoord(texCoord + texelOffsetY)).r * level.textureInfo.y;

    vec3 tangentX = vec3(level.worldOriginAndSpacing.z * 2.0, hR - hL, 0.0);
    vec3 tangentZ = vec3(0.0, hD - hU, level.worldOriginAndSpacing.z * 2.0);
    return normalize(cross(tangentZ, tangentX));
}

void main(void)
{
    vec3 barycentric = vec3(1.0 - gl_TessCoord.x - gl_TessCoord.y, gl_TessCoord.x, gl_TessCoord.y);
    vec2 gridCoord = tcGridCoord[0] * barycentric.x + tcGridCoord[1] * barycentric.y + tcGridCoord[2] * barycentric.z;
    vec2 edgeDir = tcEdgeDir[0] * barycentric.x + tcEdgeDir[1] * barycentric.y + tcEdgeDir[2] * barycentric.z;

    vLevelIndex = uPush.levelIndex;
    vParentLevelIndex = min(uPush.levelIndex + 1, CLIPMAP_LEVEL_COUNT - 1);

    ClipmapLevelUniform level = uClipmap.levels[uPush.levelIndex];
    vec2 sampleGrid = clamp(gridCoord, vec2(0.0), vec2(level.torusParams.z));
    vec2 texCoord = ComputeClipmapTexCoord(level, sampleGrid);
    float heightSample = texture(heightClipmaps[uPush.levelIndex], texCoord).r * level.textureInfo.y;

    vec2 worldXZ = level.worldOriginAndSpacing.xy + gridCoord * level.worldOriginAndSpacing.z;
    vec4 worldPosition = vec4(worldXZ.x, heightSample, worldXZ.y, 1.0);
    vec2 parentTexCoord = texCoord;
    vec3 currentNormal = ComputeNormal(uPush.levelIndex, level, texCoord);
    vec3 parentNormal = currentNormal;

    bool isSkirt = length(edgeDir) > 0.001;
    float skirtDepth = CLIPMAP_SKIRT_DEPTH * level.worldOriginAndSpacing.z;

    float morphFactor = 0.0;
    if(uPush.levelIndex < CLIPMAP_LEVEL_COUNT - 1)
    {
        float morphRange = max(level.textureInfo.w - level.textureInfo.z, 0.0001);
        float distanceToCamera = max(
            abs(worldXZ.x - uClipmap.camera.cameraWorldPosition.x),
            abs(worldXZ.y - uClipmap.camera.cameraWorldPosition.z));
        morphFactor = clamp((distanceToCamera - level.textureInfo.z) / morphRange, 0.0, 1.0);

        if(morphFactor > 0.0)
        {
            int parentIndex = uPush.levelIndex + 1;
            ClipmapLevelUniform parentLevel = uClipmap.levels[parentIndex];
            float parentSpacing = parentLevel.worldOriginAndSpacing.z;
            vec2 parentGrid = floor((worldXZ - parentLevel.worldOriginAndSpacing.xy) / parentSpacing);
            parentGrid = clamp(parentGrid, vec2(0.0), vec2(parentLevel.torusParams.z));

            parentTexCoord = ComputeClipmapTexCoord(parentLevel, parentGrid);
            float parentHeight = texture(heightClipmaps[parentIndex], parentTexCoord).r * parentLevel.textureInfo.y;
            vec2 parentXZ = parentLevel.worldOriginAndSpacing.xy + parentGrid * parentSpacing;
            vec4 parentPosition = vec4(parentXZ.x, parentHeight, parentXZ.y, 1.0);
            parentNormal = ComputeNormal(parentIndex, parentLevel, parentTexCoord);

            if(isSkirt)
            {
                float parentSkirt = CLIPMAP_SKIRT_DEPTH * parentSpacing;
                worldPosition.y -= skirtDepth;
                parentPosition.y -= parentSkirt;
                heightSample -= skirtDepth;
            }

            worldPosition = mix(worldPosition, parentPosition, morphFactor);
            worldXZ = worldPosition.xz;
            heightSample = worldPosition.y;
        }
    }

    if(isSkirt && morphFactor == 0.0)
    {
        worldPosition.y -= skirtDepth;
        heightSample -= skirtDepth;
    }

    vec3 blendedNormal = currentNormal;
    if(isSkirt)
    {
        vec3 outward = normalize(vec3(edgeDir.x, 0.0, edgeDir.y) + vec3(0.0, 1e-3, 0.0));
        blendedNormal = normalize(vec3(outward.x * 0.25, 1.0, outward.z * 0.25));
    }
    else if(morphFactor > 0.0)
    {
        blendedNormal = normalize(mix(currentNormal, parentNormal, morphFactor));
    }

    vWorldPos = worldPosition.xyz;
    vNormal = blendedNormal;
    vClipmapUV = texCoord;
    vParentClipmapUV = parentTexCoord;
    vMorphFactor = morphFactor;

    gl_Position = uClipmap.camera.viewProjectionMatrix * worldPosition;
}
