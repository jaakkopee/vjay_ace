#include "LIFToneSynth.h"

#include <SFML/Audio/SoundChannel.hpp>
#include <algorithm>
#include <cmath>

namespace {
constexpr int CHUNK_FRAMES = 512;
constexpr float TWO_PI = 6.28318530717958647692f;
}

LIFToneSynth::LIFToneSynth() {
    interleaved_.resize(static_cast<std::size_t>(CHUNK_FRAMES) * 2U, 0);

    // Log-frequency mapping (vertical axis -> tone frequency).
    const float fMin = minFreqHz_;
    const float fMax = maxFreqHz_;
    for (int i = 0; i < NUM_BINS; ++i) {
        const float t = (NUM_BINS > 1) ? static_cast<float>(i) / static_cast<float>(NUM_BINS - 1) : 0.0f;
        freqHz_[i] = fMin * std::pow(fMax / fMin, t);
    }
}

bool LIFToneSynth::startStream() {
    initialize(2, SAMPLE_RATE, {sf::SoundChannel::FrontLeft, sf::SoundChannel::FrontRight});
    setVolume(85.0f);
    play();
    return true;
}

void LIFToneSynth::stopStream() {
    stop();
}

void LIFToneSynth::setBypass(bool bypass) {
    bypassed_.store(bypass, std::memory_order_relaxed);
}

void LIFToneSynth::setFrequencyRange(float minHz, float maxHz) {
    minHz = std::clamp(minHz, 20.0f, 8000.0f);
    maxHz = std::clamp(maxHz, minHz + 10.0f, 12000.0f);
    std::scoped_lock lock(ampMutex_);
    minFreqHz_ = minHz;
    maxFreqHz_ = maxHz;
    for (int i = 0; i < NUM_BINS; ++i) {
        const float t = (NUM_BINS > 1) ? static_cast<float>(i) / static_cast<float>(NUM_BINS - 1) : 0.0f;
        freqHz_[i] = minFreqHz_ * std::pow(maxFreqHz_ / minFreqHz_, t);
    }
}

void LIFToneSynth::setColumnEnergies(const std::array<float, NUM_BINS>& energies) {
    std::scoped_lock lock(ampMutex_);
    for (int i = 0; i < NUM_BINS; ++i)
        targetAmp_[i] = std::clamp(energies[i], 0.0f, 1.0f);
}

bool LIFToneSynth::onGetData(Chunk& data) {
    if (bypassed_.load(std::memory_order_relaxed)) {
        std::fill(interleaved_.begin(), interleaved_.end(), 0);
        data.samples = interleaved_.data();
        data.sampleCount = interleaved_.size();
        return true;
    }

    std::array<float, NUM_BINS> target;
    std::array<float, NUM_BINS> freqs;
    {
        std::scoped_lock lock(ampMutex_);
        target = targetAmp_;
        freqs = freqHz_;
    }

    for (int frame = 0; frame < CHUNK_FRAMES; ++frame) {
        float sample = 0.0f;

        for (int i = 0; i < NUM_BINS; ++i) {
            currentAmp_[i] += (target[i] - currentAmp_[i]) * 0.01f;
            phase_[i] += TWO_PI * freqs[i] / static_cast<float>(SAMPLE_RATE);
            if (phase_[i] >= TWO_PI)
                phase_[i] -= TWO_PI;
            sample += std::sin(phase_[i]) * currentAmp_[i];
        }

        sample *= (0.50f / static_cast<float>(NUM_BINS));
        sample = std::clamp(sample, -1.0f, 1.0f);
        const std::int16_t s = static_cast<std::int16_t>(sample * 32767.0f);

        const std::size_t idx = static_cast<std::size_t>(frame) * 2U;
        interleaved_[idx] = s;
        interleaved_[idx + 1] = s;
    }

    data.samples = interleaved_.data();
    data.sampleCount = interleaved_.size();
    return true;
}

void LIFToneSynth::onSeek(sf::Time /*timeOffset*/) {
    phase_.fill(0.0f);
}
