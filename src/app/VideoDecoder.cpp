#include "VideoDecoder.h"
#include <iostream>

VideoDecoder::VideoDecoder() = default;

VideoDecoder::~VideoDecoder() { close(); }

bool VideoDecoder::open(const std::string& path, int outW, int outH) {
    close();
    outW_ = outW; outH_ = outH;

    if (avformat_open_input(&fmtCtx_, path.c_str(), nullptr, nullptr) < 0) {
        std::cerr << "[VideoDecoder] Cannot open: " << path << "\n";
        return false;
    }
    if (avformat_find_stream_info(fmtCtx_, nullptr) < 0) {
        close(); return false;
    }
    streamIdx_ = av_find_best_stream(fmtCtx_, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (streamIdx_ < 0) { close(); return false; }

    AVStream* stream = fmtCtx_->streams[streamIdx_];
    const AVCodec* codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) { close(); return false; }

    codecCtx_ = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(codecCtx_, stream->codecpar);
    if (avcodec_open2(codecCtx_, codec, nullptr) < 0) { close(); return false; }

    swsCtx_ = sws_getContext(
        codecCtx_->width, codecCtx_->height, codecCtx_->pix_fmt,
        outW_, outH_, AV_PIX_FMT_RGBA,
        SWS_BILINEAR, nullptr, nullptr, nullptr);
    if (!swsCtx_) { close(); return false; }

    frame_     = av_frame_alloc();
    rgbaFrame_ = av_frame_alloc();
    packet_    = av_packet_alloc();

    rgbaFrame_->format = AV_PIX_FMT_RGBA;
    rgbaFrame_->width  = outW_;
    rgbaFrame_->height = outH_;
    av_image_alloc(rgbaFrame_->data, rgbaFrame_->linesize,
                   outW_, outH_, AV_PIX_FMT_RGBA, 32);

    return true;
}

bool VideoDecoder::nextFrame(std::vector<uint8_t>& outRGBA) {
    if (!fmtCtx_) return false;

    // Read packets until we decode a video frame
    while (true) {
        int ret = av_read_frame(fmtCtx_, packet_);
        if (ret == AVERROR_EOF) {
            // Loop: seek back to start
            if (!seekToStart()) return false;
            continue;
        }
        if (ret < 0) return false;
        if (packet_->stream_index != streamIdx_) {
            av_packet_unref(packet_);
            continue;
        }
        avcodec_send_packet(codecCtx_, packet_);
        av_packet_unref(packet_);

        ret = avcodec_receive_frame(codecCtx_, frame_);
        if (ret == AVERROR(EAGAIN)) continue;
        if (ret < 0) return false;

        // Scale to RGBA
        sws_scale(swsCtx_,
                  frame_->data, frame_->linesize, 0, codecCtx_->height,
                  rgbaFrame_->data, rgbaFrame_->linesize);
        av_frame_unref(frame_);

        // Copy to output buffer
        std::size_t byteCount = outW_ * outH_ * 4;
        outRGBA.resize(byteCount);
        // rgbaFrame_->data[0] is contiguous for RGBA8
        std::memcpy(outRGBA.data(), rgbaFrame_->data[0], byteCount);
        return true;
    }
}

bool VideoDecoder::seekToStart() {
    return av_seek_frame(fmtCtx_, streamIdx_, 0, AVSEEK_FLAG_BACKWARD) >= 0;
}

void VideoDecoder::close() {
    if (swsCtx_)   { sws_freeContext(swsCtx_); swsCtx_ = nullptr; }
    if (frame_)    { av_frame_free(&frame_); }
    if (rgbaFrame_){
        if (rgbaFrame_->data[0]) av_freep(&rgbaFrame_->data[0]);
        av_frame_free(&rgbaFrame_);
    }
    if (packet_)   { av_packet_free(&packet_); }
    if (codecCtx_) { avcodec_free_context(&codecCtx_); }
    if (fmtCtx_)   { avformat_close_input(&fmtCtx_); }
    streamIdx_ = -1;
}
