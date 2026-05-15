#include <metal_stdlib>
using namespace metal;

struct Params {
    int int_params[16];
    float float_params[16];
};

// Box blur compute shader - simpler than Gaussian, uniform weights
kernel void box_blur(
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
    
    int kernel_size = params.int_params[0];
    int half_size = kernel_size / 2;
    float weight = 1.0f / float(kernel_size * kernel_size);
    
    float4 sum = float4(0.0);
    
    for (int ky = -half_size; ky <= half_size; ky++) {
        for (int kx = -half_size; kx <= half_size; kx++) {
            int2 pos = int2(gid);
            pos.x = clamp(pos.x + kx, 0, width - 1);
            pos.y = clamp(pos.y + ky, 0, height - 1);
            
            float4 pixel = input.read(uint2(pos));
            sum += pixel;
        }
    }
    
    output.write(sum * weight, gid);
}
