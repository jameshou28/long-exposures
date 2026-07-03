//
//  BlendKernels.metal
//  long-exposures
//
//  linear-light reduction kernels
//

#include <metal_stdlib>
using namespace metal;

static inline float srgb_to_linear(float c) {
    return (c <= 0.04045f) ? (c / 12.92f)
                           : pow((c + 0.055f) / 1.055f, 2.4f);
}

// inverse sRGB EOTF (linear -> gamma).
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

struct WarpParams {
    float  t;          // sample time in (0,1) between frame A and frame B
    float  flowScale;  // frame width / flow measuredWidth: flow px -> frame px
    float2 shakeDelta; // registration translation delta A->B, in pixels at the
                       // flow's measured resolution (zero when alignment is off)
};

kernel void accumulateInterpolated(
    texture2d<float, access::sample>      frameA  [[texture(0)]],
    texture2d<float, access::sample>      frameB  [[texture(1)]],
    texture2d<float, access::sample>      flowTex [[texture(2)]],
    texture2d<float, access::read_write>  minTex  [[texture(3)]],
    texture2d<float, access::read_write>  maxTex  [[texture(4)]],
    texture2d<float, access::read_write>  sumTex  [[texture(5)]],
    constant WarpParams& p                        [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= sumTex.get_width() || gid.y >= sumTex.get_height()) { return; }
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

    float2 size = float2(sumTex.get_width(), sumTex.get_height());
    float2 uv   = (float2(gid) + 0.5f) / size;
    float2 f   = (flowTex.sample(s, uv).xy - p.shakeDelta) * p.flowScale;
    float2 fuv = f / size;

    float3 a = srgb_to_linear3(frameA.sample(s, uv - p.t * fuv).rgb);
    float3 b = srgb_to_linear3(frameB.sample(s, uv + (1.0f - p.t) * fuv).rgb);
    float3 lin = mix(a, b, p.t);

    float4 mn = minTex.read(gid); mn.rgb = min(mn.rgb, lin); minTex.write(mn, gid);
    float4 mx = maxTex.read(gid); mx.rgb = max(mx.rgb, lin); maxTex.write(mx, gid);
    float4 sm = sumTex.read(gid); sm.rgb += lin; sm.a += 1.0f; sumTex.write(sm, gid);
}

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
