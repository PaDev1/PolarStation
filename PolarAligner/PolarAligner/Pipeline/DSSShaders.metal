#include <metal_stdlib>
using namespace metal;

struct DSSVertex {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct DSSOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex DSSOut dss_vertex(DSSVertex in [[stage_in]]) {
    DSSOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    return out;
}

// DSS plates are grayscale scans. Tint with a cool blue so they read as sky imagery.
// Tint values match the SwiftUI colorMultiply(0.55, 0.75, 1.0) applied previously.
fragment float4 dss_fragment(DSSOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 color = tex.sample(s, in.texCoord);
    // Apply opacity (0.85) and blue tint in one multiply
    return color * float4(0.55 * 0.85, 0.75 * 0.85, 1.0 * 0.85, 0.85);
}
