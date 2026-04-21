#pragma once
#include "Constants.h"
#include <SFML/Graphics.hpp>
#include <vector>
#include <cstdint>

// ── PerformanceWindow ─────────────────────────────────────────────────────────
// Screen 2 — borderless full-screen projection window.
// Displays the Metal-composited output texture, stretched to fill the screen.
// No UI widgets — just the pixel output.

class PerformanceWindow {
public:
    PerformanceWindow();

    // Open borderless full-screen on the display at (displayX, displayY).
    void open(int displayX, int displayY, int width, int height);
    bool isOpen() const;
    void close();

    bool handleEvents();

    // Upload composited RGBA8 pixel data (WORK_W × WORK_H) and blit to screen.
    void present(const std::vector<uint8_t>& rgbaPixels);

    // Show a black frame (called when compositor has no output yet).
    void clearBlack();

private:
    sf::RenderWindow window_;
    sf::Texture      outputTex_;
    bool             texReady_ = false;
};
