#version 450 core
#extension GL_ARB_separate_shader_objects : enable

#define CLIPMAP_LEVEL_COUNT 9

const float gClipmapMinTessFactor = 1.0;

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

layout(vertices = 3) out;

layout(location = 0) in vec2 vGridCoord[];
layout(location = 1) in vec2 vEdgeDir[];
layout(location = 0) out vec2 tcGridCoord[];
layout(location = 1) out vec2 tcEdgeDir[];

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

void main(void)
{
    tcGridCoord[gl_InvocationID] = vGridCoord[gl_InvocationID];
    gl_out[gl_InvocationID].gl_Position = vec4(vGridCoord[gl_InvocationID], 0.0, 1.0);

    if(gl_InvocationID == 0)
    {
        ClipmapLevelUniform level = uClipmap.levels[uPush.levelIndex];
        vec2 patchCenterGrid = (vGridCoord[0] + vGridCoord[1] + vGridCoord[2]) / 3.0;
        vec2 texCoord = ComputeClipmapTexCoord(level, patchCenterGrid);
        float heightSample = texture(heightClipmaps[uPush.levelIndex], texCoord).r * level.textureInfo.y;
        vec2 worldXZ = level.worldOriginAndSpacing.xy + patchCenterGrid * level.worldOriginAndSpacing.z;
        vec4 worldPosition = vec4(worldXZ.x, heightSample, worldXZ.y, 1.0);

        float morphRange = max(level.textureInfo.w - level.textureInfo.z, 0.0001);
        float distanceToCamera = max(
            abs(worldPosition.x - uClipmap.camera.cameraWorldPosition.x),
            abs(worldPosition.z - uClipmap.camera.cameraWorldPosition.z));
        float tessBlend = clamp((level.textureInfo.w - distanceToCamera) / morphRange, 0.0, 1.0);
        float tessLevel = mix(gClipmapMinTessFactor, level.torusParams.w, tessBlend);

        gl_TessLevelOuter[0] = tessLevel;
        gl_TessLevelOuter[1] = tessLevel;
        gl_TessLevelOuter[2] = tessLevel;
        gl_TessLevelInner[0] = tessLevel;
    }

    tcEdgeDir[gl_InvocationID] = vEdgeDir[gl_InvocationID];
}
