#include <metal_stdlib>
using namespace metal;

struct DebayerParams {
    uint width;
    uint height;
    uint bytesPerPixel;
    uint bayerOffsetX;  // 0 or 1: column offset for Red pixel
    uint bayerOffsetY;  // 0 or 1: row offset for Red pixel
    uint flipX;         // 1 = mirror horizontally
    uint flipY;         // 1 = flip vertically
};

struct StretchParams {
    float blackPoint;
    float whitePoint;
    float midtones;    // MTF balance parameter (0..1); 0.5 = linear (no stretch)
    uint  useSTF;      // 1 = use MTF auto-stretch, 0 = simple linear + gamma
};

// Sample a raw Bayer pixel with clamped coordinates, returning normalized [0,1].
static float sample_raw(device const uchar *rawBuffer, uint sx, uint sy,
                         uint w, uint h, uint bpp) {
    sx = clamp(sx, 0u, w - 1);
    sy = clamp(sy, 0u, h - 1);
    uint idx = sy * w + sx;
    if (bpp == 2) {
        device const ushort *raw16 = (device const ushort *)rawBuffer;
        return float(raw16[idx]) / 65535.0;
    }
    return float(rawBuffer[idx]) / 255.0;
}

/// Generic Bayer pattern debayer to RGBA half-float.
/// Uses bilinear interpolation for demosaicing.
/// Supports all 4 patterns via bayerOffsetX/Y:
///   RGGB: (0,0)   GRBG: (1,0)   GBRG: (0,1)   BGGR: (1,1)
kernel void debayer_rggb(
    device const uchar *rawBuffer [[buffer(0)]],
    texture2d<half, access::write> output [[texture(0)]],
    constant DebayerParams &params [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) return;

    // Read from flipped source coordinates, write to normal output position
    uint x = params.flipX ? (params.width - 1 - gid.x) : gid.x;
    uint y = params.flipY ? (params.height - 1 - gid.y) : gid.y;
    uint w = params.width;
    uint h = params.height;
    uint bpp = params.bytesPerPixel;

    float r, g, b;

    // Apply bayer offset to determine pixel role
    uint px = (x + params.bayerOffsetX) % 2;
    uint py = (y + params.bayerOffsetY) % 2;

    float c = sample_raw(rawBuffer, x, y, w, h, bpp);

    if (px == 0 && py == 0) {
        // Red pixel
        r = c;
        g = (sample_raw(rawBuffer, x-1, y, w, h, bpp) +
             sample_raw(rawBuffer, x+1, y, w, h, bpp) +
             sample_raw(rawBuffer, x, y-1, w, h, bpp) +
             sample_raw(rawBuffer, x, y+1, w, h, bpp)) * 0.25;
        b = (sample_raw(rawBuffer, x-1, y-1, w, h, bpp) +
             sample_raw(rawBuffer, x+1, y-1, w, h, bpp) +
             sample_raw(rawBuffer, x-1, y+1, w, h, bpp) +
             sample_raw(rawBuffer, x+1, y+1, w, h, bpp)) * 0.25;
    } else if (px == 1 && py == 0) {
        // Green pixel on red row
        g = c;
        r = (sample_raw(rawBuffer, x-1, y, w, h, bpp) +
             sample_raw(rawBuffer, x+1, y, w, h, bpp)) * 0.5;
        b = (sample_raw(rawBuffer, x, y-1, w, h, bpp) +
             sample_raw(rawBuffer, x, y+1, w, h, bpp)) * 0.5;
    } else if (px == 0 && py == 1) {
        // Green pixel on blue row
        g = c;
        r = (sample_raw(rawBuffer, x, y-1, w, h, bpp) +
             sample_raw(rawBuffer, x, y+1, w, h, bpp)) * 0.5;
        b = (sample_raw(rawBuffer, x-1, y, w, h, bpp) +
             sample_raw(rawBuffer, x+1, y, w, h, bpp)) * 0.5;
    } else {
        // Blue pixel
        b = c;
        g = (sample_raw(rawBuffer, x-1, y, w, h, bpp) +
             sample_raw(rawBuffer, x+1, y, w, h, bpp) +
             sample_raw(rawBuffer, x, y-1, w, h, bpp) +
             sample_raw(rawBuffer, x, y+1, w, h, bpp)) * 0.25;
        r = (sample_raw(rawBuffer, x-1, y-1, w, h, bpp) +
             sample_raw(rawBuffer, x+1, y-1, w, h, bpp) +
             sample_raw(rawBuffer, x-1, y+1, w, h, bpp) +
             sample_raw(rawBuffer, x+1, y+1, w, h, bpp)) * 0.25;
    }

    output.write(half4(half(r), half(g), half(b), 1.0h), gid);
}

// MARK: - Fullscreen blit (used by CameraPreviewView to render texture to drawable)

struct BlitVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Generates a fullscreen triangle (3 vertices, no vertex buffer needed).
vertex BlitVertexOut blit_vertex(uint vid [[vertex_id]]) {
    BlitVertexOut out;
    // Fullscreen triangle covering clip space [-1,1]
    float2 pos = float2((vid == 1) ? 3.0 : -1.0,
                        (vid == 2) ? 3.0 : -1.0);
    out.position = float4(pos, 0.0, 1.0);
    // Map to UV [0,1], flip Y for Metal texture coordinates
    out.texCoord = float2((pos.x + 1.0) * 0.5, (1.0 - pos.y) * 0.5);
    return out;
}

fragment half4 blit_fragment(BlitVertexOut in [[stage_in]],
                              texture2d<half> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.texCoord);
}

/// Midtone Transfer Function (MTF).
/// MTF(x, m) = ((m-1)*x) / (((2m-1)*x) - m)
/// Maps 0→0, m→0.5, 1→1. Lower m = more aggressive stretch.
static float mtf(float x, float m) {
    if (x <= 0.0) return 0.0;
    if (x >= 1.0) return 1.0;
    return ((m - 1.0) * x) / (((2.0 * m - 1.0) * x) - m);
}

/// Auto-stretch: map [blackPoint, whitePoint] to [0, 1] for display.
/// When useSTF=1, applies Midtone Transfer Function (STF auto-stretch).
/// When useSTF=0, applies simple linear stretch + gamma 2.2.
kernel void auto_stretch(
    texture2d<half, access::read>  input  [[texture(0)]],
    texture2d<half, access::write> output [[texture(1)]],
    constant StretchParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;

    half4 pixel = input.read(gid);

    float range = max(params.whitePoint - params.blackPoint, 0.001);
    float3 rgb = float3(pixel.rgb);

    // Linear stretch to [0, 1]
    rgb = saturate((rgb - params.blackPoint) / range);

    if (params.useSTF != 0) {
        // STF: apply MTF per channel
        rgb.r = mtf(rgb.r, params.midtones);
        rgb.g = mtf(rgb.g, params.midtones);
        rgb.b = mtf(rgb.b, params.midtones);
    } else {
        // Simple gamma correction for display
        rgb = pow(rgb, float3(1.0 / 2.2));
    }

    // Output as BGRA for CAMetalLayer
    output.write(half4(half(rgb.b), half(rgb.g), half(rgb.r), 1.0h), gid);
}
