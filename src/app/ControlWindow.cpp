#include "ControlWindow.h"
#include <cmath>
#include <algorithm>
#include <cstdio>

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

// ── GUI construction ────────────────────────────────────────────────────────────────────
const tgui::Color BG_DARK   {16,  16,  20 };
const tgui::Color TEXT_DIM  {150, 165, 195};
const tgui::Color TEXT_VAL  {215, 225, 255};

void ControlWindow::buildGui(int width, int /*height*/) {
    leftColW_       = width / 2;
    const int slotW = leftColW_ / 3;

    // ── Scene name ───────────────────────────────────────────────────────────────
    sceneLabel_ = tgui::Label::create("SCENE: None");
    sceneLabel_->setPosition(14, 12);
    sceneLabel_->setTextSize(22);
    sceneLabel_->getRenderer()->setTextColor(tgui::Color(255, 210, 80));
    gui_.add(sceneLabel_);

    // ── Mode label ──────────────────────────────────────────────────────────────
    modeLabel_ = tgui::Label::create("Mode: FX Param  |  CC: 3  9  12  13  14  15");
    modeLabel_->setPosition(14, 50);
    modeLabel_->setTextSize(13);
    modeLabel_->getRenderer()->setTextColor(TEXT_DIM);
    gui_.add(modeLabel_);

    // ── 6 knobs: 2 rows × 3 columns ─────────────────────────────────────────────────
    // Row 0 (knobs 0-2): y=96;  row 1 (knobs 3-5): y=96+KNOB_SIZE+90
    const int rowYBase[2] = { 96, 96 + KNOB_SIZE + 90 };

    for (int i = 0; i < NUM_KNOBS; ++i) {
        auto& ks        = knobs_[i];
        const int row   = i / 3;
        const int col   = i % 3;
        const int kx    = col * slotW + (slotW - KNOB_SIZE) / 2;
        const int ky    = rowYBase[row];

        // Knob canvas
        ks.canvas = tgui::CanvasSFML::create({KNOB_SIZE, KNOB_SIZE});
        ks.canvas->setPosition(kx, ky);
        gui_.add(ks.canvas);

        // Parameter name label (centred in slot)
        ks.paramLabel = tgui::Label::create("--");
        ks.paramLabel->setPosition(col * slotW, ky + KNOB_SIZE + 5);
        ks.paramLabel->setSize(slotW, 24);
        ks.paramLabel->setHorizontalAlignment(tgui::HorizontalAlignment::Center);
        ks.paramLabel->setTextSize(13);
        ks.paramLabel->getRenderer()->setTextColor(TEXT_DIM);
        gui_.add(ks.paramLabel);

        // Value label (centred in slot)
        ks.valueLabel = tgui::Label::create("0.00");
        ks.valueLabel->setPosition(col * slotW, ky + KNOB_SIZE + 30);
        ks.valueLabel->setSize(slotW, 26);
        ks.valueLabel->setHorizontalAlignment(tgui::HorizontalAlignment::Center);
        ks.valueLabel->setTextSize(15);
        ks.valueLabel->getRenderer()->setTextColor(TEXT_VAL);
        gui_.add(ks.valueLabel);

        drawKnob(i);
    }

    // ── Right panel: video monitor ─────────────────────────────────────────────
    rightPanel_ = tgui::Panel::create({static_cast<float>(width - leftColW_), "100%"});
    rightPanel_->setPosition(leftColW_, 0);
    rightPanel_->getRenderer()->setBackgroundColor(tgui::Color(0, 0, 0));
    gui_.add(rightPanel_, "rightPanel");
}

// ── Knob drawing ────────────────────────────────────────────────────────────────────────
void ControlWindow::drawKnob(int idx) {
    auto& ks = knobs_[idx];
    if (!ks.canvas) return;
    ks.canvas->clear(tgui::Color(22, 22, 28));
    auto& rt = ks.canvas->getRenderTexture();

    const float      norm = static_cast<float>(ks.ccValue) / 127.0f;
    const KnobColour kc   = ccToKnobColour(ks.ccValue);

    // Background circle
    sf::CircleShape bg(KNOB_SIZE / 2.0f - 2.0f);
    bg.setPosition({2.0f, 2.0f});
    bg.setFillColor(sf::Color(38, 38, 50));
    bg.setOutlineColor(sf::Color(kc.r / 2, kc.g / 2, kc.b / 2));
    bg.setOutlineThickness(2.0f);
    rt.draw(bg);

    // Value arc: 7-o'clock start, 240° sweep
    const float cx         = KNOB_SIZE / 2.0f;
    const float cy         = KNOB_SIZE / 2.0f;
    const float radius     = KNOB_SIZE / 2.0f - 7.0f;
    const float startAngle = 150.0f * (3.14159f / 180.0f);
    const float sweep      = 240.0f * (3.14159f / 180.0f);
    const int   steps      = static_cast<int>(norm * 64);

    for (int s = 0; s <= steps; ++s) {
        float angle = startAngle + (static_cast<float>(s) / 64.0f) * sweep;
        float x2 = cx + std::cos(angle) * radius;
        float y2 = cy + std::sin(angle) * radius;
        sf::VertexArray line(sf::PrimitiveType::Lines, 2);
        line[0].position = {cx, cy};
        line[0].color    = sf::Color(kc.r, kc.g, kc.b, 180);
        line[1].position = {x2, y2};
        line[1].color    = sf::Color(kc.r, kc.g, kc.b, 255);
        rt.draw(line);
    }

    // Centre dot
    sf::CircleShape dot(4.0f);
    dot.setPosition({cx - 4.0f, cy - 4.0f});
    dot.setFillColor(sf::Color(220, 225, 255, 190));
    rt.draw(dot);

    ks.canvas->display();
}

// ── State setters ───────────────────────────────────────────────────────────────────────
void ControlWindow::setKnobValue(int knobIdx, int ccValue) {
    if (knobIdx < 0 || knobIdx >= NUM_KNOBS) return;
    auto& ks   = knobs_[knobIdx];
    ks.ccValue = std::clamp(ccValue, 0, 127);
    char buf[12];
    std::snprintf(buf, sizeof(buf), "%.2f", ks.ccValue / 127.0f);
    if (ks.valueLabel) ks.valueLabel->setText(buf);
    drawKnob(knobIdx);
}

void ControlWindow::setKnobParamName(int knobIdx, const std::string& name) {
    if (knobIdx < 0 || knobIdx >= NUM_KNOBS) return;
    if (knobs_[knobIdx].paramLabel) knobs_[knobIdx].paramLabel->setText(name);
}

void ControlWindow::setSceneName(const std::string& name) {
    if (sceneLabel_) sceneLabel_->setText("SCENE: " + name);
}

void ControlWindow::setKnobMode(KnobMode mode) {
    static const char* names[] = {"Layer Opacity", "Audio Gain", "FX Param", "Img Rotate", "Img Zoom"};
    if (modeLabel_)
        modeLabel_->setText(std::string("Mode: ") + names[static_cast<int>(mode)]
                            + "  |  CC: 3  9  12  13  14  15");
}

// ── Input handling ────────────────────────────────────────────────────────────────────
void ControlWindow::onMousePressed(float x, float y) {
    for (int i = 0; i < NUM_KNOBS; ++i) {
        auto& ks = knobs_[i];
        if (!ks.canvas) continue;
        auto pos = ks.canvas->getPosition();
        auto sz  = ks.canvas->getSize();
        if (x >= pos.x && x < pos.x + sz.x &&
            y >= pos.y && y < pos.y + sz.y) {
            drag_ = {true, i, ks.ccValue, y};
            return;
        }
    }
}

void ControlWindow::onMouseReleased() { drag_.active = false; }

void ControlWindow::onMouseMoved(float /*x*/, float y) {
    if (!drag_.active) return;
    float delta = drag_.startY - y;   // drag up = increase
    int newCC = std::clamp(static_cast<int>(drag_.startCC + delta), 0, 127);
    // Re-anchor each frame so there is no dead zone when a limit is hit.
    drag_.startCC = newCC;
    drag_.startY  = y;
    setKnobValue(drag_.knob, newCC);
    if (onKnobDrag) onKnobDrag(drag_.knob, ccToNorm(newCC));
}

// ── Frame ───────────────────────────────────────────────────────────────────────────────
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
        if (const auto* kp = event->getIf<sf::Event::KeyPressed>()) {
            (void)kp; // key state is polled in update() instead
        }
        if (const auto* kr = event->getIf<sf::Event::KeyReleased>()) {
            (void)kr;
        }
    }
    return true;
}

void ControlWindow::update() {
    // Poll R and Z key state each frame — robust against TGUI consuming key events.
    bool rNow = sf::Keyboard::isKeyPressed(sf::Keyboard::Key::R);
    bool zNow = sf::Keyboard::isKeyPressed(sf::Keyboard::Key::Z);
    if (rNow != rKeyWas_) { rKeyWas_ = rNow; if (onRKey) onRKey(rNow); }
    if (zNow != zKeyWas_) { zKeyWas_ = zNow; if (onZKey) onZKey(zNow); }
}

void ControlWindow::render(const sf::Texture& compositePreview) {
    window_.clear(sf::Color(16, 16, 20));

    // Video monitor: letterboxed in right half
    const float pw   = static_cast<float>(window_.getSize().x - leftColW_);
    const float ph   = static_cast<float>(window_.getSize().y);
    const float texW = static_cast<float>(compositePreview.getSize().x);
    const float texH = static_cast<float>(compositePreview.getSize().y);
    if (pw > 0 && ph > 0 && texW > 0 && texH > 0) {
        const float scale = std::min(pw / texW, ph / texH);
        sf::Sprite spr(compositePreview);
        spr.setScale({scale, scale});
        spr.setPosition({
            static_cast<float>(leftColW_) + (pw - texW * scale) * 0.5f,
            (ph - texH * scale) * 0.5f
        });
        window_.draw(spr);
    }

    gui_.draw();
    window_.display();
}

