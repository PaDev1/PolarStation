#include <metal_stdlib>
using namespace metal;

/// Parameters for the centroid extraction kernel.
struct CentroidParams {
    uint width;          // Image width
    uint height;         // Image height
    uint halfWidth;      // Half-width of centroid window
    float threshold;     // Minimum pixel value to include
    uint maxCandidates;  // Max entries in candidate buffer
};

/// A star candidate found by peak detection.
struct StarCandidate {
    float x;           // Peak pixel X
    float y;           // Peak pixel Y
    float peakValue;   // Peak brightness
};

/// Output of sub-pixel centroid refinement.
struct CentroidResult {
    float x;           // Sub-pixel X
    float y;           // Sub-pixel Y
    float brightness;  // Integrated flux
    float fwhm;        // Estimated FWHM
    float snr;         // Signal-to-noise estimate
    uint valid;        // 1 if valid, 0 if rejected
};

/// Sub-pixel centroid refinement using intensity-weighted center of mass.
///
/// For each star candidate, computes the centroid in an (2*hw+1)x(2*hw+1) window
/// around the peak pixel. Also estimates FWHM and SNR.
///
/// Input:  Grayscale image (r16Float or luminance from rgba16Float)
///         Array of star candidates
/// Output: Array of refined centroid results
kernel void refine_centroids(
    texture2d<float, access::read> image [[texture(0)]],
    device const StarCandidate *candidates [[buffer(0)]],
    device CentroidResult *results [[buffer(1)]],
    constant CentroidParams &params [[buffer(2)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= params.maxCandidates) return;

    StarCandidate cand = candidates[gid];
    int cx = int(cand.x);
    int cy = int(cand.y);
    int hw = int(params.halfWidth);

    // Intensity-weighted centroid
    float sumIx = 0.0;
    float sumIy = 0.0;
    float sumI = 0.0;
    float maxVal = 0.0;

    // First pass: estimate local background from window edges
    float bgSum = 0.0;
    float bgCount = 0.0;
    for (int dy = -hw; dy <= hw; dy++) {
        for (int dx = -hw; dx <= hw; dx++) {
            if (abs(dx) == hw || abs(dy) == hw) {
                int px = clamp(cx + dx, 0, int(params.width) - 1);
                int py = clamp(cy + dy, 0, int(params.height) - 1);
                float val = image.read(uint2(px, py)).r;
                bgSum += val;
                bgCount += 1.0;
            }
        }
    }
    float background = bgCount > 0.0 ? bgSum / bgCount : 0.0;

    // Estimate background noise (std dev of edge pixels)
    float bgVarSum = 0.0;
    for (int dy = -hw; dy <= hw; dy++) {
        for (int dx = -hw; dx <= hw; dx++) {
            if (abs(dx) == hw || abs(dy) == hw) {
                int px = clamp(cx + dx, 0, int(params.width) - 1);
                int py = clamp(cy + dy, 0, int(params.height) - 1);
                float val = image.read(uint2(px, py)).r;
                float diff = val - background;
                bgVarSum += diff * diff;
            }
        }
    }
    float noise = bgCount > 1.0 ? sqrt(bgVarSum / (bgCount - 1.0)) : 1.0;

    // Second pass: compute centroid on background-subtracted values
    float sumR2I = 0.0; // For FWHM estimation

    for (int dy = -hw; dy <= hw; dy++) {
        for (int dx = -hw; dx <= hw; dx++) {
            int px = clamp(cx + dx, 0, int(params.width) - 1);
            int py = clamp(cy + dy, 0, int(params.height) - 1);
            float val = image.read(uint2(px, py)).r - background;
            if (val > 0.0) {
                sumIx += val * float(px);
                sumIy += val * float(py);
                sumI += val;
                float r2 = float(dx * dx + dy * dy);
                sumR2I += val * r2;
                maxVal = max(maxVal, val);
            }
        }
    }

    CentroidResult result;

    if (sumI > 0.0 && maxVal > params.threshold) {
        result.x = sumIx / sumI;
        result.y = sumIy / sumI;
        result.brightness = sumI;

        // FWHM from second moment: sigma = sqrt(sum(I*r^2)/sum(I)), FWHM = 2.355*sigma
        float sigma = sqrt(sumR2I / sumI);
        result.fwhm = 2.355 * sigma;

        // SNR = peak signal / background noise (minimum noise floor for uniform backgrounds)
        float effectiveNoise = max(noise, 1e-4);
        result.snr = maxVal / effectiveNoise;
        result.valid = 1;
    } else {
        result.x = cand.x;
        result.y = cand.y;
        result.brightness = 0.0;
        result.fwhm = 0.0;
        result.snr = 0.0;
        result.valid = 0;
    }

    results[gid] = result;
}

/// Convert RGBA half-float image to single-channel luminance.
/// Luminance = 0.299*R + 0.587*G + 0.114*B
kernel void rgba_to_luminance(
    texture2d<half, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;

    half4 pixel = input.read(gid);
    float lum = 0.299 * float(pixel.r) + 0.587 * float(pixel.g) + 0.114 * float(pixel.b);
    output.write(float4(lum, 0.0, 0.0, 1.0), gid);
}
