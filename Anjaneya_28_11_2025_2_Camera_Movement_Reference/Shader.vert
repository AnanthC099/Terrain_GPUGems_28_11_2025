#version 450 core
#extension GL_ARB_separate_shader_objects : enable

#define CLIPMAP_LEVEL_COUNT 9

layout(location = 0) in vec2 inGrid;
layout(location = 1) in vec2 inEdgeDir;

layout(location = 0) out vec2 vGridCoord;
layout(location = 1) out vec2 vEdgeDir;

struct ClipmapLevelUniform
{
    vec4 worldOriginAndSpacing; // xyz = (originX, originZ, sampleSpacingWorld)
    vec4 textureInfo; // x = invTextureSize, y = heightScale, z = morphStart, w = morphEnd
    vec4 torusParams; // xy = texel offsets
};

struct ClipmapCameraUniform
{
    mat4 viewMatrix;
    mat4 projectionMatrix;
    mat4 viewProjectionMatrix;
    vec4 cameraWorldPosition;
};

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

void main(void)
{
    vGridCoord = inGrid;
    vEdgeDir = inEdgeDir;
}
