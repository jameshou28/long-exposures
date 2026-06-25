//
//  BlendKernels.metal
//  long-exposures
//
//  Placeholder Metal file to wire the Metal toolchain.
//  Real blend kernels (average, lighten, darken) land in Phase 2.
//

#include <metal_stdlib>
using namespace metal;

// No-op pass-through. Replaced in Phase 2 by the linear-light reduction kernel.
kernel void blend_passthrough(texture2d<float, access::read>  inTexture  [[texture(0)]],
                              texture2d<float, access::write> outTexture [[texture(1)]],
                              uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) {
        return;
    }
    float4 color = inTexture.read(gid);
    outTexture.write(color, gid);
}
