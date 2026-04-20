#include "PerformanceWindow.h"
#include <SFML/Window/VideoMode.hpp>

PerformanceWindow::PerformanceWindow() = default;

void PerformanceWindow::open(int displayX, int displayY, int width, int height) {
    window_.create(sf::VideoMode({static_cast<unsigned>(width),
                                  static_cast<unsigned>(height)}),
                   "vjay_ace - Output",
                   sf::Style::None);   // borderless
    window_.setPosition({displayX, displayY});
    window_.setFramerateLimit(60);
    window_.setVerticalSyncEnabled(true);

    // Pre-allocate output texture at working resolution
    if (!outputTex_.resize({WORK_W, WORK_H}))
        throw std::runtime_error("PerformanceWindow: cannot create output texture");
    texReady_ = true;
}

bool PerformanceWindow::isOpen() const { return window_.isOpen(); }
void PerformanceWindow::close()        { window_.close(); }

bool PerformanceWindow::handleEvents() {
    while (const auto event = window_.pollEvent()) {
        if (event->is<sf::Event::Closed>()) { window_.close(); return false; }
        // ESC to close
        if (const auto* kp = event->getIf<sf::Event::KeyPressed>())
            if (kp->code == sf::Keyboard::Key::Escape) { window_.close(); return false; }
    }
    return true;
}

void PerformanceWindow::present(const std::vector<uint8_t>& rgbaPixels) {
    if (!texReady_ || rgbaPixels.size() < static_cast<std::size_t>(WORK_W * WORK_H * 4))
        return;

    outputTex_.update(rgbaPixels.data());

    // Scale to fill screen, maintaining aspect ratio
    sf::Sprite spr(outputTex_);
    auto wSize = window_.getSize();
    float scaleX = static_cast<float>(wSize.x) / static_cast<float>(WORK_W);
    float scaleY = static_cast<float>(wSize.y) / static_cast<float>(WORK_H);
    // Use fill (stretch): for projection, stretching to fill is often preferred
    // Switch to std::min(scaleX, scaleY) to preserve aspect ratio instead.
    spr.setScale({scaleX, scaleY});

    window_.clear(sf::Color::Black);
    window_.draw(spr);
    window_.display();
}
