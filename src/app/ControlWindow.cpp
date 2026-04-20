#include "ControlWindow.h"
#include <cmath>
#include <algorithm>

ControlWindow::ControlWindow() = default;

void ControlWindow::open(int displayX, int displayY, int width, int height) {
    window_.create(sf::VideoMode({static_cast<unsigned>(width),
                                  static_cast<unsigned>(height)}),
                   "vjay_ace - Control");
    window_.setPosition({displayX, displayY});
    window_.setFramerateLimit(60);
    gui_.setWindow(window_);
    buildGui(width, height);
}

bool ControlWindow::isOpen() const { return window_.isOpen(); }
void ControlWindow::close()        { window_.close(); }

// ── GUI construction ──────────────────────────────────────────────────────────

void ControlWindow::buildGui(int width, int height) {
    // Mode label at top
    modeLabel_ = tgui::Label::create("Mode: FX Param");
    modeLabel_->setPosition(8, 4);
    modeLabel_->setTextSize(14);
    modeLabel_->getRenderer()->setTextColor(tgui::Color(180, 220, 255));
    gui_.add(modeLabel_);

    // Left column: 6 rows (one per FX slot / layer pair)
    for (int row = 0; row < NUM_ROWS; ++row) {
        int yBase = 28 + row * ROW_H;

        // Effect name label
        effectLabels_[row] = tgui::Label::create("Layer " + std::to_string(row));
        effectLabels_[row]->setPosition(8, yBase + 8);
        effectLabels_[row]->setTextSize(13);
        effectLabels_[row]->getRenderer()->setTextColor(tgui::Color(200, 200, 200));
        gui_.add(effectLabels_[row]);

        // 6 knob canvases
        for (int k = 0; k < NUM_KNOBS; ++k) {
            auto& ks = knobs_[row][k];
            int xKnob = 120 + k * (KNOB_SIZE + 6);
            ks.canvas = tgui::Canvas::create({KNOB_SIZE, KNOB_SIZE});
            ks.canvas->setPosition(xKnob, yBase + (ROW_H - KNOB_SIZE) / 2);
            gui_.add(ks.canvas);
            drawKnob(ks, row, k);
        }
    }

    // Right column: preview panel
    rightPanel_ = tgui::Panel::create({static_cast<float>(width - LEFT_COL_W), "100%"});
    rightPanel_->setPosition(LEFT_COL_W, 0);
    rightPanel_->getRenderer()->setBackgroundColor(tgui::Color(10, 10, 10));
    gui_.add(rightPanel_, "rightPanel");
}

// ── Knob drawing ─────────────────────────────────────────────────────────────

void ControlWindow::drawKnob(KnobState& ks, int /*row*/, int /*knob*/) {
    if (!ks.canvas) return;
    auto& rt = ks.canvas->getRenderTexture();
    rt.clear(sf::Color(25, 25, 30));

    float norm = static_cast<float>(ks.ccValue) / 127.0f;
    KnobColour kc = ccToKnobColour(ks.ccValue);

    // Background circle
    sf::CircleShape bg(KNOB_SIZE / 2.0f - 2.0f);
    bg.setPosition({2.0f, 2.0f});
    bg.setFillColor(sf::Color(40, 40, 50));
    bg.setOutlineColor(sf::Color(kc.r, kc.g, kc.b));
    bg.setOutlineThickness(2.0f);
    rt.draw(bg);

    // Value arc: draw as a filled wedge using lines from centre
    float cx = KNOB_SIZE / 2.0f;
    float cy = KNOB_SIZE / 2.0f;
    float radius = KNOB_SIZE / 2.0f - 6.0f;
    float startAngle = 150.0f * (3.14159f / 180.0f); // 150° (7 o'clock)
    float sweepAngle = 240.0f * (3.14159f / 180.0f); // 240° sweep

    int arcSteps = static_cast<int>(norm * 60);
    for (int s = 0; s <= arcSteps; ++s) {
        float angle = startAngle + (static_cast<float>(s) / 60.0f) * sweepAngle;
        float x2 = cx + std::cos(angle) * radius;
        float y2 = cy + std::sin(angle) * radius;
        sf::VertexArray line(sf::PrimitiveType::Lines, 2);
        line[0].position = {cx, cy};
        line[0].color    = sf::Color(kc.r, kc.g, kc.b, 200);
        line[1].position = {x2, y2};
        line[1].color    = sf::Color(kc.r, kc.g, kc.b, 255);
        rt.draw(line);
    }

    // Centre dot
    sf::CircleShape dot(3.0f);
    dot.setPosition({cx - 3.0f, cy - 3.0f});
    dot.setFillColor(sf::Color(255, 255, 255, 160));
    rt.draw(dot);

    rt.display();
}

// ── Public state setters ──────────────────────────────────────────────────────

void ControlWindow::setKnobValue(int layerRow, int knobIdx, int ccValue) {
    if (layerRow < 0 || layerRow >= NUM_ROWS) return;
    if (knobIdx < 0  || knobIdx  >= NUM_KNOBS) return;
    auto& ks = knobs_[layerRow][knobIdx];
    ks.ccValue = std::clamp(ccValue, 0, 127);
    drawKnob(ks, layerRow, knobIdx);
}

void ControlWindow::setEffectName(int row, const std::string& name) {
    if (row < 0 || row >= NUM_ROWS) return;
    if (effectLabels_[row]) effectLabels_[row]->setText(name);
}

void ControlWindow::setKnobMode(KnobMode mode) {
    static const char* names[] = {"Layer Opacity", "FX Audio/BPF", "FX Param"};
    if (modeLabel_)
        modeLabel_->setText("Mode: " + std::string(names[static_cast<int>(mode)]));
}

// ── Input handling ────────────────────────────────────────────────────────────

void ControlWindow::onMousePressed(float x, float y) {
    for (int row = 0; row < NUM_ROWS; ++row) {
        for (int k = 0; k < NUM_KNOBS; ++k) {
            auto& ks = knobs_[row][k];
            if (!ks.canvas) continue;
            auto pos  = ks.canvas->getPosition();
            auto size = ks.canvas->getSize();
            if (x >= pos.x && x < pos.x + size.x &&
                y >= pos.y && y < pos.y + size.y) {
                drag_ = {true, row, k, ks.ccValue, y};
                return;
            }
        }
    }
}

void ControlWindow::onMouseReleased() { drag_.active = false; }

void ControlWindow::onMouseMoved(float x, float y) {
    (void)x;
    if (!drag_.active) return;
    float delta = drag_.startY - y;              // drag up = increase
    int newCC = std::clamp(static_cast<int>(drag_.startCC + delta), 0, 127);
    setKnobValue(drag_.row, drag_.knob, newCC);
    if (onKnobDrag)
        onKnobDrag(drag_.row, drag_.knob, ccToNorm(newCC));
}

// ── Frame ─────────────────────────────────────────────────────────────────────

bool ControlWindow::handleEvents() {
    while (const auto event = window_.pollEvent()) {
        gui_.handleEvent(*event);
        if (event->is<sf::Event::Closed>()) { window_.close(); return false; }
        if (const auto* mp = event->getIf<sf::Event::MouseButtonPressed>())
            onMousePressed(static_cast<float>(mp->position.x),
                           static_cast<float>(mp->position.y));
        if (event->is<sf::Event::MouseButtonReleased>())
            onMouseReleased();
        if (const auto* mm = event->getIf<sf::Event::MouseMoved>())
            onMouseMoved(static_cast<float>(mm->position.x),
                         static_cast<float>(mm->position.y));
    }
    return true;
}

void ControlWindow::update() { /* future: animations */ }

void ControlWindow::render(const sf::Texture& compositePreview) {
    window_.clear(sf::Color(18, 18, 22));

    // Draw the composite preview in the right column
    sf::Sprite spr(compositePreview);
    auto ppos  = rightPanel_->getPosition();
    auto psize = rightPanel_->getSize();
    float scaleX = psize.x / static_cast<float>(compositePreview.getSize().x);
    float scaleY = psize.y / static_cast<float>(compositePreview.getSize().y);
    float scale  = std::min(scaleX, scaleY);
    spr.setScale({scale, scale});
    spr.setPosition({ppos.x + (psize.x - compositePreview.getSize().x * scale) * 0.5f,
                     ppos.y + (psize.y - compositePreview.getSize().y * scale) * 0.5f});
    window_.draw(spr);

    gui_.draw();
    window_.display();
}
