#include <metal_stdlib>
using namespace metal;

// Edge detection using Sobel operator
kernel void edge_detect(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    int width = input.get_width();
    int height = input.get_height();
    
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    
    // Sobel kernels
    const int sobelX[3][3] = {
        {-1, 0, 1},
        {-2, 0, 2},
        {-1, 0, 1}
    };
    
    const int sobelY[3][3] = {
        {-1, -2, -1},
        { 0,  0,  0},
        { 1,  2,  1}
    };
    
    float4 gx = float4(0.0);
    float4 gy = float4(0.0);
    int2 pos = int2(gid);
    
    // Apply Sobel kernels
    for (int ky = -1; ky <= 1; ky++) {
        for (int kx = -1; kx <= 1; kx++) {
            int2 sample_pos = pos;
            sample_pos.x = clamp(sample_pos.x + kx, 0, width - 1);
            sample_pos.y = clamp(sample_pos.y + ky, 0, height - 1);
            
            float4 pixel = input.read(uint2(sample_pos));
            
            gx += pixel * float(sobelX[ky + 1][kx + 1]);
            gy += pixel * float(sobelY[ky + 1][kx + 1]);
        }
    }
    
    // Calculate gradient magnitude
    float4 magnitude = sqrt(gx * gx + gy * gy);
    
    output.write(clamp(magnitude, 0.0f, 1.0f), gid);
}
