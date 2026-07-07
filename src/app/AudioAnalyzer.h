#pragma once
#include <array>
#include <atomic>
#include <vector>
#include <functional>
#include <thread>
#include <mutex>
#include <AudioUnit/AudioUnit.h>

// ── AudioAnalyzer ─────────────────────────────────────────────────────────────
// Captures audio from the default input device via Core Audio, computes an
// 8-band magnitude spectrum and an RMS level using vDSP, and makes the results
// available lock-free for the render thread to read.
//
// Band layout (logarithmically spaced, 44100 Hz sample rate, 2048-pt FFT):
//   0  Sub-bass    20–60 Hz
//   1  Bass        60–250 Hz
//   2  Lo-mid      250–500 Hz
//   3  Mid         500–2 kHz
//   4  Hi-mid      2–4 kHz
//   5  Presence    4–6 kHz
//   6  Brilliance  6–12 kHz
//   7  Air         12–20 kHz

class AudioAnalyzer {
public:
    static constexpr int NUM_BANDS = 8;
    static constexpr int FFT_SIZE  = 2048;

    AudioAnalyzer();
    ~AudioAnalyzer();

    // Start / stop audio capture.
    // inputDeviceIndex: audio input device (-1 = default)
    // outputDeviceIndex: audio output device (-1 = default)
    bool start(int inputDeviceIndex = -1, int outputDeviceIndex = -1);
    void stop();
    bool isRunning() const { return running_; }

    // Read latest 8-band magnitudes (0.0–1.0, log-scaled) and RMS (0.0–1.0).
    // Safe to call from any thread; internally lock-free via double-buffer swap.
    std::array<float, NUM_BANDS> bands() const;
    float rms() const { return rms_.load(std::memory_order_relaxed); }
    float peak() const { return peak_.load(std::memory_order_relaxed); }

    // Smoothing factor applied to band magnitudes each frame (0 = instant, 1 = frozen).
    float smoothing = 0.75f;

    // Core Audio AUHAL units (not AVAudioEngine) - public for callback access
    void* inputUnit_  = nullptr;  // AudioUnit for input
    void* outputUnit_ = nullptr;  // AudioUnit for output/passthrough

    // Process audio block - public for callbacks
    void processBlockPublic(const float* samples, int count) {
        processBlock(samples, count);
    }

private:

    // Ring buffer for incoming PCM (single-channel float32)
    std::vector<float> ring_;
    int ringWrite_ = 0;
    std::mutex ringMutex_;

    // Double-buffer for output bands
    mutable std::mutex outMutex_;
    std::array<float, NUM_BANDS> bands_ = {};
    std::atomic<float> rms_  {0.0f};
    std::atomic<float> peak_ {0.0f};

    bool running_ = false;

    int selectedInputDeviceIndex_ = -1;
    int selectedOutputDeviceIndex_ = -1;
    float sampleRate_ = 44100.0f;

    // vDSP FFT state (opaque pointer to avoid header coupling)
    void* fftSetup_ = nullptr;
    std::vector<float> window_;
    std::vector<float> fftReal_;
    std::vector<float> fftImag_;
    std::vector<float> magnitude_;

    void computeFFT(const float* samples);
    float bandMagnitude(int binLo, int binHi) const;
    void processBlock(const float* samples, int count);
};

