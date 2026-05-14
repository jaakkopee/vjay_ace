#pragma once

#include <SFML/Audio/SoundStream.hpp>
#include <array>
#include <cstdint>
#include <mutex>
#include <vector>

// Experimental audio renderer:
// Maps vertical LIF activity bins to oscillator frequencies and scans time along X.
class LIFToneSynth : public sf::SoundStream {
public:
    static constexpr unsigned SAMPLE_RATE = 48000;
    static constexpr int NUM_BINS = 16;

    LIFToneSynth();
    bool startStream();
    void stopStream();

    // Input energies are expected in [0..1]. Bin index maps low->high frequency.
    void setColumnEnergies(const std::array<float, NUM_BINS>& energies);

private:
    [[nodiscard]] bool onGetData(Chunk& data) override;
    void onSeek(sf::Time timeOffset) override;

    std::array<float, NUM_BINS> targetAmp_{};
    std::array<float, NUM_BINS> currentAmp_{};
    std::array<float, NUM_BINS> phase_{};
    std::array<float, NUM_BINS> freqHz_{};

    std::mutex ampMutex_;
    std::vector<std::int16_t> interleaved_;
};
