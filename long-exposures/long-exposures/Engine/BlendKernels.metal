//
//  BlendKernels.metal
//  long-exposures
//
//  Phase 2: linear-light reduction kernels.
//
//  Strategy: accumulate frame-by-frame into a float32 texture, one frame per
//  dispatch. Each kernel reads the running accumulator plus the incoming frame
//  and writes the updated accumulator. Input frames are sRGB BGRA; we convert
//  to linear light on read so blending is physically correct. A final resolve
//  kernel converts the accumulator back to sRGB for display/export.
//
//  - average: accumulate the sum; resolve divides by frame count.
//  - lighten: running per-channel max (light trails).
//  - darken:  running per-channel min.
//

#include <metal_stdlib>
using namespace metal;

// sRGB EOTF (gamma -> linear). Operates per-channel on RGB; alpha passes through.
static inline float srgb_to_linear(float c) {
    return (c <= 0.04045f) ? (c / 12.92f)
                           : pow((c + 0.055f) / 1.055f, 2.4f);
}

// Inverse sRGB EOTF (linear -> gamma).
static inline float linear_to_srgb(float c) {
    return (c <= 0.0031308f) ? (c * 12.92f)
                             : (1.055f * pow(c, 1.0f / 2.4f) - 0.055f);
}

static inline float3 srgb_to_linear3(float3 c) {
    return float3(srgb_to_linear(c.r), srgb_to_linear(c.g), srgb_to_linear(c.b));
}

static inline float3 linear_to_srgb3(float3 c) {
    return float3(linear_to_srgb(c.r), linear_to_srgb(c.g), linear_to_srgb(c.b));
}

// --- Accumulation kernels -------------------------------------------------
//
// accumulator: float32 RGBA texture, read_write. Caller zero-fills (average)
// or seeds with the first frame (lighten/darken) before the first dispatch.
// frame: the incoming sRGB frame for this step.

kernel void accumulate_average(texture2d<float, access::read>        frame       [[texture(0)]],
                               texture2d<float, access::read_write>  accumulator [[texture(1)]],
                               uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= accumulator.get_width() || gid.y >= accumulator.get_height()) { return; }
    float4 src = frame.read(gid);
    float4 acc = accumulator.read(gid);
    acc.rgb += srgb_to_linear3(src.rgb);
    acc.a   += 1.0f; // frame count, kept per-pixel for a uniform resolve path
    accumulator.write(acc, gid);
}

// Lighten/darken keep the per-channel extreme in `accumulator.rgb`, and a running
// average in a parallel `mean` texture (rgb = linear sum, a = frame count). Resolve
// mixes the average toward the extreme by a fixed strength so the effect is softened
// instead of pinning every pixel to the single brightest/darkest frame.
kernel void accumulate_lighten(texture2d<float, access::read>        frame       [[texture(0)]],
                               texture2d<float, access::read_write>  accumulator [[texture(1)]],
                               texture2d<float, access::read_write>  mean        [[texture(2)]],
                               uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= accumulator.get_width() || gid.y >= accumulator.get_height()) { return; }
    float3 lin = srgb_to_linear3(frame.read(gid).rgb);
    float4 acc = accumulator.read(gid);
    acc.rgb = max(acc.rgb, lin);
    accumulator.write(acc, gid);
    float4 m = mean.read(gid);
    m.rgb += lin;
    m.a   += 1.0f;
    mean.write(m, gid);
}

kernel void accumulate_darken(texture2d<float, access::read>        frame       [[texture(0)]],
                              texture2d<float, access::read_write>  accumulator [[texture(1)]],
                              texture2d<float, access::read_write>  mean        [[texture(2)]],
                              uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= accumulator.get_width() || gid.y >= accumulator.get_height()) { return; }
    float3 lin = srgb_to_linear3(frame.read(gid).rgb);
    float4 acc = accumulator.read(gid);
    acc.rgb = min(acc.rgb, lin);
    accumulator.write(acc, gid);
    float4 m = mean.read(gid);
    m.rgb += lin;
    m.a   += 1.0f;
    mean.write(m, gid);
}

// --- Resolve --------------------------------------------------------------
//
// Converts the linear accumulator to an sRGB BGRA8 output texture.
// divideByCount: 1 for average (divide acc.rgb by acc.a), 0 for lighten/darken.
// For lighten/darken, the per-pixel average lives in `mean` (rgb = sum, a = count)
// and `strength` (0..1) blends that average toward the extreme so the effect is
// dialed back from the full, often-harsh max/min.

kernel void resolve(texture2d<float, access::read>   accumulator [[texture(0)]],
                    texture2d<float, access::write>  outTexture  [[texture(1)]],
                    texture2d<float, access::read>   mean        [[texture(2)]],
                    constant uint& divideByCount                 [[buffer(0)]],
                    constant float& strength                     [[buffer(1)]],
                    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) { return; }
    float4 acc = accumulator.read(gid);
    float3 linearColor;
    if (divideByCount != 0) {
        float count = max(acc.a, 1.0f);
        linearColor = acc.rgb / count;
    } else {
        float4 m = mean.read(gid);
        float3 avg = m.rgb / max(m.a, 1.0f);
        linearColor = mix(avg, acc.rgb, strength);
    }
    float3 srgb = saturate(linear_to_srgb3(linearColor));
    outTexture.write(float4(srgb, 1.0f), gid);
}
