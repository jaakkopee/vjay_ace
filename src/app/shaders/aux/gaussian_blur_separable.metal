#include <metal_stdlib>
using namespace metal;

// Separable Gaussian Blur - Horizontal Pass
// Optimized: O(n) instead of O(n²) complexity
kernel void gaussian_blur_horizontal(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant int& kernel_size [[buffer(0)]],
    constant float& sigma [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    
    // Generate Gaussian kernel on-the-fly (small kernel, worth it)
    int half_kernel = kernel_size / 2;
    float gauss_kernel[32]; // Max kernel size 32
    float sum = 0.0f;
    
    for (int i = 0; i < kernel_size; i++) {
        float x = float(i - half_kernel);
        gauss_kernel[i] = exp(-(x * x) / (2.0f * sigma * sigma));
        sum += gauss_kernel[i];
    }
    
    // Normalize
    for (int i = 0; i < kernel_size; i++) {
        gauss_kernel[i] /= sum;
    }
    
    // Horizontal blur
    float4 result = float4(0.0f);
    for (int k = 0; k < kernel_size; k++) {
        int px = int(gid.x) + k - half_kernel;
        px = clamp(px, 0, int(input.get_width()) - 1);
        result += input.read(uint2(px, gid.y)) * gauss_kernel[k];
    }
    
    output.write(result, gid);
}

// Separable Gaussian Blur - Vertical Pass
kernel void gaussian_blur_vertical(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant int& kernel_size [[buffer(0)]],
    constant float& sigma [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    
    // Generate Gaussian kernel
    int half_kernel = kernel_size / 2;
    float gauss_kernel[32];
    float sum = 0.0f;
    
    for (int i = 0; i < kernel_size; i++) {
        float x = float(i - half_kernel);
        gauss_kernel[i] = exp(-(x * x) / (2.0f * sigma * sigma));
        sum += gauss_kernel[i];
    }
    
    for (int i = 0; i < kernel_size; i++) {
        gauss_kernel[i] /= sum;
    }
    
    // Vertical blur
    float4 result = float4(0.0f);
    for (int k = 0; k < kernel_size; k++) {
        int py = int(gid.y) + k - half_kernel;
        py = clamp(py, 0, int(input.get_height()) - 1);
        result += input.read(uint2(gid.x, py)) * gauss_kernel[k];
    }
    
    output.write(result, gid);
}
