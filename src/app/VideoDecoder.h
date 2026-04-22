#pragma once
#include <string>
#include <vector>
#include <cstdint>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
}

// ── VideoDecoder ─────────────────────────────────────────────────────────────
// Wraps FFmpeg to decode a video or image file frame-by-frame.
// Output is always RGBA8 at the requested width/height (software scale).

class VideoDecoder {
public:
    VideoDecoder();
    ~VideoDecoder();

    // Open file. Returns false on error.
    bool open(const std::string& path, int outW, int outH);

    // Decode the next frame into outRGBA (sized outW*outH*4).
    // Loops back to start at EOF.
    // Returns false if no frame was available yet.
    bool nextFrame(std::vector<uint8_t>& outRGBA);

    bool isOpen() const { return fmtCtx_ != nullptr; }

private:
    AVFormatContext* fmtCtx_   = nullptr;
    AVCodecContext*  codecCtx_ = nullptr;
    SwsContext*      swsCtx_   = nullptr;
    AVFrame*         frame_    = nullptr;
    AVFrame*         rgbaFrame_= nullptr;
    AVPacket*        packet_   = nullptr;
    int              streamIdx_= -1;
    int              outW_     = 0;
    int              outH_     = 0;
    // Aspect-ratio-fitted region within the output frame
    int              fitW_     = 0;
    int              fitH_     = 0;
    int              offX_     = 0;  // left edge of centred image
    int              offY_     = 0;  // top  edge of centred image

    void close();
    bool seekToStart();

    bool isStatic_  = false;          // true after first EOF — single-frame file
    bool hasCached_ = false;          // true once pixelCache_ holds a valid frame
    std::vector<uint8_t> pixelCache_; // decoded RGBA pixels for static images
};
