//
//  BlendKernels.metal
//  long-exposures
//
//  Phase 2: linear-light reduction kernels.
//
//  Strategy: accumulate frame-by-frame into float32 textures, one frame per
//  dispatch. A single accumulate kernel tracks everything the blend can need at
//  once — the running per-channel min, the running per-channel max, and the
//  running sum + count (for the average). Input frames are sRGB BGRA; we convert
//  to linear light on read so blending is physically correct.
//
//  Because all three quantities are accumulated together, the blend "mode" is a
//  continuous slider resolved at the end: a signed bias in [-1, +1] mixes the
//  average toward the darken (min) extreme on the negative side and the lighten
//  (max) extreme on the positive side. 0 is a plain average. The resolve kernel
//  converts the chosen linear colour back to sRGB for display/export.
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

// --- Accumulation ---------------------------------------------------------
//
// Three read_write textures, all float32 RGBA at frame size:
//   minTex: running per-channel min   (rgb), seeded to +inf so the first min wins.
//   maxTex: running per-channel max   (rgb), seeded to 0   so the first max wins.
//   sumTex: running sum (rgb) + count (a), seeded to 0.
// The caller seeds these (see BlendEngine.makeAccumulators) and dispatches this
// kernel once per frame, with a memory barrier between dispatches so each frame's
// write is visible to the next (the read-modify-write chain must run in order).

kernel void accumulate(texture2d<float, access::read>        frame  [[texture(0)]],
                       texture2d<float, access::read_write>  minTex [[texture(1)]],
                       texture2d<float, access::read_write>  maxTex [[texture(2)]],
                       texture2d<float, access::read_write>  sumTex [[texture(3)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= sumTex.get_width() || gid.y >= sumTex.get_height()) { return; }
    float3 lin = srgb_to_linear3(frame.read(gid).rgb);

    float4 mn = minTex.read(gid);
    mn.rgb = min(mn.rgb, lin);
    minTex.write(mn, gid);

    float4 mx = maxTex.read(gid);
    mx.rgb = max(mx.rgb, lin);
    maxTex.write(mx, gid);

    float4 s = sumTex.read(gid);
    s.rgb += lin;
    s.a   += 1.0f;
    sumTex.write(s, gid);
}

// --- Resolve --------------------------------------------------------------
//
// Converts the accumulated linear data to an sRGB BGRA8 output texture.
// `bias` in [-1, +1] picks where on the darken<->average<->lighten axis to land:
//   bias <  0 : mix(avg, min, -bias)  -> toward darken
//   bias == 0 : avg                   -> plain average
//   bias >  0 : mix(avg, max,  bias)  -> toward lighten

kernel void resolve(texture2d<float, access::read>   minTex     [[texture(0)]],
                    texture2d<float, access::read>   maxTex     [[texture(1)]],
                    texture2d<float, access::read>   sumTex     [[texture(2)]],
                    texture2d<float, access::write>  outTexture [[texture(3)]],
                    constant float& bias                        [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) { return; }

    float4 s = sumTex.read(gid);
    float3 avg = s.rgb / max(s.a, 1.0f);

    float3 linearColor;
    if (bias < 0.0f) {
        float3 mn = minTex.read(gid).rgb;
        linearColor = mix(avg, mn, -bias);
    } else if (bias > 0.0f) {
        float3 mx = maxTex.read(gid).rgb;
        linearColor = mix(avg, mx, bias);
    } else {
        linearColor = avg;
    }

    float3 srgb = saturate(linear_to_srgb3(linearColor));
    outTexture.write(float4(srgb, 1.0f), gid);
}
