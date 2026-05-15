#include <metal_stdlib>
using namespace metal;

struct Params {
    int int_params[16];
    float float_params[16];
};

// Sharpen filter compute shader
kernel void sharpen(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int width = input.get_width();
    int height = input.get_height();
    
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    
    float strength = params.float_params[0];
    // Sharpen kernel weights (adjusted by strength)
    // Center: 1 + 4*strength, Neighbors: -strength
    float center_weight = 1.0f + 4.0f * strength;
    float neighbor_weight = -strength;
    
    float4 sum = float4(0.0);
    int2 pos = int2(gid);
    
    // 3x3 kernel
    for (int ky = -1; ky <= 1; ky++) {
        for (int kx = -1; kx <= 1; kx++) {
            int2 sample_pos = pos;
            sample_pos.x = clamp(sample_pos.x + kx, 0, width - 1);
            sample_pos.y = clamp(sample_pos.y + ky, 0, height - 1);
            
            float4 pixel = input.read(uint2(sample_pos));
            
            // Apply appropriate weight
            if (kx == 0 && ky == 0) {
                sum += pixel * center_weight;
            } else if ((kx == 0) != (ky == 0)) {  // Cross pattern only
                sum += pixel * neighbor_weight;
            }
        }
    }
    
    output.write(clamp(sum, 0.0f, 1.0f), gid);
}
