#include <SFML/Window/Keyboard.hpp>
#include "ControlWindow.h"
#include "CapsLockDetector.h"
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

    // ── Caps Lock indicator label ───────────────────────────────────────────
    shiftLockLabel_ = tgui::Label::create("Caps Lock: Off");
    shiftLockLabel_->setPosition(14, 70);
    shiftLockLabel_->setTextSize(13);
    shiftLockLabel_->getRenderer()->setTextColor(TEXT_DIM);
    gui_.add(shiftLockLabel_);

    // ── Pressure meter ─────────────────────────────────────────────────────────
    pressureLabel_ = tgui::Label::create("Pressure CH10: 0%");
    pressureLabel_->setPosition(14, 88);
    pressureLabel_->setTextSize(12);
    pressureLabel_->getRenderer()->setTextColor(tgui::Color(170, 220, 255));
    gui_.add(pressureLabel_);

    pressureMeterCanvas_ = tgui::CanvasSFML::create({static_cast<float>(leftColW_ - 28), 14.0f});
    pressureMeterCanvas_->setPosition(14, 106);
    gui_.add(pressureMeterCanvas_);

    // ── LIF MIDI output controls ─────────────────────────────────────────
    lifMidiToggleBtn_ = tgui::Button::create("Enable LIF MIDI (M)");
    lifMidiToggleBtn_->setPosition(14, 124);
    lifMidiToggleBtn_->setSize(leftColW_ - 28, 26);
    lifMidiToggleBtn_->onPress([this] {
        if (onLIFMidiToggle) onLIFMidiToggle();
    });
    gui_.add(lifMidiToggleBtn_);

    lifMidiStatusLabel_ = tgui::Label::create("LIF MIDI: Off");
    lifMidiStatusLabel_->setPosition(14, 152);
    lifMidiStatusLabel_->setTextSize(12);
    lifMidiStatusLabel_->getRenderer()->setTextColor(TEXT_DIM);
    gui_.add(lifMidiStatusLabel_);

    lifMidiStyleBtn_ = tgui::Button::create("LIF MIDI Style: Pop");
    lifMidiStyleBtn_->setPosition(14, 172);
    lifMidiStyleBtn_->setSize(leftColW_ - 28, 22);
    lifMidiStyleBtn_->onPress([this] {
        if (onLIFMidiStyleCycle)
            onLIFMidiStyleCycle();
    });
    gui_.add(lifMidiStyleBtn_);

    lifToneVolLabel_ = tgui::Label::create("LIF Tone Vol: 85%");
    lifToneVolLabel_->setPosition(14, 198);
    lifToneVolLabel_->setTextSize(12);
    lifToneVolLabel_->getRenderer()->setTextColor(TEXT_DIM);
    gui_.add(lifToneVolLabel_);

    lifToneVolDownBtn_ = tgui::Button::create("Vol -");
    lifToneVolDownBtn_->setPosition(14, 218);
    lifToneVolDownBtn_->setSize(70, 22);
    lifToneVolDownBtn_->onPress([this] {
        if (onLIFToneVolumeNudge)
            onLIFToneVolumeNudge(-5.0f);
    });
    gui_.add(lifToneVolDownBtn_);

    lifToneVolUpBtn_ = tgui::Button::create("Vol +");
    lifToneVolUpBtn_->setPosition(90, 218);
    lifToneVolUpBtn_->setSize(70, 22);
    lifToneVolUpBtn_->onPress([this] {
        if (onLIFToneVolumeNudge)
            onLIFToneVolumeNudge(5.0f);
    });
    gui_.add(lifToneVolUpBtn_);

    // ── MIDI Settings dropdown section ──────────────────────────────────
    midiSettingsBtn_ = tgui::Button::create("MIDI Settings ▼");
    midiSettingsBtn_->setPosition(14, 246);
    midiSettingsBtn_->setSize(leftColW_ - 28, 24);
    midiSettingsBtn_->onPress([this] {
        midiSettingsExpanded_ = !midiSettingsExpanded_;
        if (midiSettingsPanel_)
            midiSettingsPanel_->setVisible(midiSettingsExpanded_);
        if (midiSettingsBtn_)
            midiSettingsBtn_->setText(midiSettingsExpanded_ ? "MIDI Settings ▲" : "MIDI Settings ▼");
    });
    gui_.add(midiSettingsBtn_);

    midiSettingsPanel_ = tgui::Panel::create({static_cast<float>(leftColW_ - 28), 128.0f});
    midiSettingsPanel_->setPosition(14, 272);
    midiSettingsPanel_->getRenderer()->setBackgroundColor(tgui::Color(24, 24, 32));
    midiSettingsPanel_->setVisible(false);
    gui_.add(midiSettingsPanel_);

    auto midiInLabel = tgui::Label::create("Input");
    midiInLabel->setPosition(6, 4);
    midiInLabel->setTextSize(11);
    midiInLabel->getRenderer()->setTextColor(TEXT_DIM);
    midiSettingsPanel_->add(midiInLabel);

    midiInPortBox_ = tgui::ComboBox::create();
    midiInPortBox_->setPosition(6, 20);
    midiInPortBox_->setSize(leftColW_ - 40, 22);
    midiInPortBox_->setDefaultText("Select MIDI input");
    midiInPortBox_->onItemSelect([this] {
        if (onMidiInPortChanged)
            onMidiInPortChanged(midiInPortBox_->getSelectedItem().toStdString());
    });
    midiSettingsPanel_->add(midiInPortBox_);

    auto midiOutLabel = tgui::Label::create("Output");
    midiOutLabel->setPosition(6, 46);
    midiOutLabel->setTextSize(11);
    midiOutLabel->getRenderer()->setTextColor(TEXT_DIM);
    midiSettingsPanel_->add(midiOutLabel);

    midiOutPortBox_ = tgui::ComboBox::create();
    midiOutPortBox_->setPosition(80, 44);
    midiOutPortBox_->setSize(leftColW_ - 114, 22);
    midiOutPortBox_->setDefaultText("Select MIDI output");
    midiOutPortBox_->onItemSelect([this] {
        if (onMidiOutPortChanged)
            onMidiOutPortChanged(midiOutPortBox_->getSelectedItem().toStdString());
    });
    midiSettingsPanel_->add(midiOutPortBox_);

    lifMidiKeyLabel_ = tgui::Label::create("Key: C");
    lifMidiKeyLabel_->setPosition(6, 72);
    lifMidiKeyLabel_->setTextSize(11);
    lifMidiKeyLabel_->getRenderer()->setTextColor(TEXT_DIM);
    midiSettingsPanel_->add(lifMidiKeyLabel_);

    lifMidiKeyDownBtn_ = tgui::Button::create("Key -");
    lifMidiKeyDownBtn_->setPosition(80, 68);
    lifMidiKeyDownBtn_->setSize(56, 22);
    lifMidiKeyDownBtn_->onPress([this] {
        if (onLIFMidiKeyNudge)
            onLIFMidiKeyNudge(-1);
    });
    midiSettingsPanel_->add(lifMidiKeyDownBtn_);

    lifMidiKeyUpBtn_ = tgui::Button::create("Key +");
    lifMidiKeyUpBtn_->setPosition(140, 68);
    lifMidiKeyUpBtn_->setSize(56, 22);
    lifMidiKeyUpBtn_->onPress([this] {
        if (onLIFMidiKeyNudge)
            onLIFMidiKeyNudge(1);
    });
    midiSettingsPanel_->add(lifMidiKeyUpBtn_);

    lifMidiRangeLabel_ = tgui::Label::create("Range: 36-96");
    lifMidiRangeLabel_->setPosition(6, 100);
    lifMidiRangeLabel_->setTextSize(11);
    lifMidiRangeLabel_->getRenderer()->setTextColor(TEXT_DIM);
    midiSettingsPanel_->add(lifMidiRangeLabel_);

    lifMidiRangeMinDownBtn_ = tgui::Button::create("Lo-");
    lifMidiRangeMinDownBtn_->setPosition(80, 94);
    lifMidiRangeMinDownBtn_->setSize(32, 22);
    lifMidiRangeMinDownBtn_->onPress([this] {
        if (onLIFMidiRangeMinNudge)
            onLIFMidiRangeMinNudge(-1);
    });
    midiSettingsPanel_->add(lifMidiRangeMinDownBtn_);

    lifMidiRangeMinUpBtn_ = tgui::Button::create("Lo+");
    lifMidiRangeMinUpBtn_->setPosition(116, 94);
    lifMidiRangeMinUpBtn_->setSize(32, 22);
    lifMidiRangeMinUpBtn_->onPress([this] {
        if (onLIFMidiRangeMinNudge)
            onLIFMidiRangeMinNudge(1);
    });
    midiSettingsPanel_->add(lifMidiRangeMinUpBtn_);

    lifMidiRangeMaxDownBtn_ = tgui::Button::create("Hi-");
    lifMidiRangeMaxDownBtn_->setPosition(152, 94);
    lifMidiRangeMaxDownBtn_->setSize(32, 22);
    lifMidiRangeMaxDownBtn_->onPress([this] {
        if (onLIFMidiRangeMaxNudge)
            onLIFMidiRangeMaxNudge(-1);
    });
    midiSettingsPanel_->add(lifMidiRangeMaxDownBtn_);

    lifMidiRangeMaxUpBtn_ = tgui::Button::create("Hi+");
    lifMidiRangeMaxUpBtn_->setPosition(188, 94);
    lifMidiRangeMaxUpBtn_->setSize(32, 22);
    lifMidiRangeMaxUpBtn_->onPress([this] {
        if (onLIFMidiRangeMaxNudge)
            onLIFMidiRangeMaxNudge(1);
    });
    midiSettingsPanel_->add(lifMidiRangeMaxUpBtn_);

    // ── 6 knobs: 2 rows × 3 columns ─────────────────────────────────────────────────
    // Keep the grid below the expanded MIDI settings panel so panel buttons stay clickable.
    const int rowYBase[2] = { 420, 420 + KNOB_SIZE + 90 };

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

        // Topology name label (centred below value)
        ks.topoNameLabel = tgui::Label::create("");
        ks.topoNameLabel->setPosition(col * slotW, ky + KNOB_SIZE + 56);
        ks.topoNameLabel->setSize(slotW, 20);
        ks.topoNameLabel->setHorizontalAlignment(tgui::HorizontalAlignment::Center);
        ks.topoNameLabel->setTextSize(12);
        ks.topoNameLabel->getRenderer()->setTextColor(tgui::Color(200, 200, 220));
        gui_.add(ks.topoNameLabel);

        drawKnob(i);
    }

    // ── Audio level meter canvas ──────────────────────────────────────────────
    // Placed below the knob grid, spanning the left panel.
    const int meterY = 112 + KNOB_SIZE + 90 + KNOB_SIZE + 70;  // below row-1 value labels
    const int meterH = 80;

    auto meterLabel = tgui::Label::create("AUDIO");
    meterLabel->setPosition(6, meterY - 18);
    meterLabel->setTextSize(11);
    meterLabel->getRenderer()->setTextColor(TEXT_DIM);
    gui_.add(meterLabel);

    audioMeterCanvas_ = tgui::CanvasSFML::create(
        {static_cast<float>(leftColW_ - 8), static_cast<float>(meterH)});
    audioMeterCanvas_->setPosition(4, meterY);
    gui_.add(audioMeterCanvas_);

    // ── Right panel: video monitor ─────────────────────────────────────────────
    rightPanel_ = tgui::Panel::create({static_cast<float>(width - leftColW_), "100%"});
    rightPanel_->setPosition(leftColW_, 0);
    rightPanel_->getRenderer()->setBackgroundColor(tgui::Color(0, 0, 0, 0)); // transparent — sprite drawn behind gui_.draw()
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

void ControlWindow::setKnobTopoName(int knobIdx, const std::string& name) {
    if (knobIdx < 0 || knobIdx >= NUM_KNOBS) return;
    if (knobs_[knobIdx].topoNameLabel) knobs_[knobIdx].topoNameLabel->setText(name);
}

void ControlWindow::setSceneName(const std::string& name) {
    if (sceneLabel_) sceneLabel_->setText("SCENE: " + name);
}

void ControlWindow::setKnobMode(KnobMode mode) {
    static const char* names[] = {
        "Layer Opacity", "Audio Gain", "FX Param", "Img Rotate", "Img Zoom", "Img Pan"
    };
    if (modeLabel_)
        modeLabel_->setText(std::string("Mode: ") + names[static_cast<int>(mode)]
                            + "  |  CC: 3  9  12  13  14  15");
}

void ControlWindow::setPressureNorm(float norm) {
    pressureNorm_ = std::clamp(norm, 0.0f, 1.0f);
    if (pressureLabel_) {
        char buf[48];
        std::snprintf(buf, sizeof(buf), "Pressure CH10: %d%%", static_cast<int>(pressureNorm_ * 100.0f + 0.5f));
        pressureLabel_->setText(buf);
    }
}

void ControlWindow::setLifToneVolume(float volume) {
    if (!lifToneVolLabel_)
        return;
    const float clamped = std::clamp(volume, 0.0f, 100.0f);
    char buffer[48];
    std::snprintf(buffer, sizeof(buffer), "LIF Tone Vol: %d%%", static_cast<int>(clamped + 0.5f));
    lifToneVolLabel_->setText(buffer);
}

void ControlWindow::setLifMidiStatus(bool enabled, int channel, int baseNote) {
    if (!lifMidiStatusLabel_ || !lifMidiToggleBtn_) return;
    char buf[96];
    std::snprintf(buf, sizeof(buf), "LIF MIDI: %s (Ch %d, Notes %d-%d)",
                  enabled ? "On" : "Off", channel, baseNote, baseNote + 15);
    lifMidiStatusLabel_->setText(buf);
    lifMidiStatusLabel_->getRenderer()->setTextColor(enabled ? tgui::Color(80, 255, 120) : TEXT_DIM);
    lifMidiToggleBtn_->setText(enabled ? "Disable LIF MIDI (M)" : "Enable LIF MIDI (M)");
}

void ControlWindow::setLifMidiStyle(const std::string& styleName) {
    if (!lifMidiStyleBtn_)
        return;
    lifMidiStyleBtn_->setText("LIF MIDI Style: " + styleName);
}

void ControlWindow::setLifMidiKey(const std::string& keyName) {
    if (!lifMidiKeyLabel_)
        return;
    lifMidiKeyLabel_->setText("Key: " + keyName);
}

void ControlWindow::setLifMidiRange(int minNote, int maxNote) {
    if (!lifMidiRangeLabel_)
        return;
    char buf[64];
    std::snprintf(buf, sizeof(buf), "Range: %d-%d", minNote, maxNote);
    lifMidiRangeLabel_->setText(buf);
}

void ControlWindow::setMidiPortLists(const std::vector<std::string>& inPorts,
                                     int inIdx,
                                     const std::vector<std::string>& outPorts,
                                     int outIdx) {
    if (midiInPortBox_) {
        midiInPortBox_->removeAllItems();
        for (const auto& name : inPorts)
            midiInPortBox_->addItem(name);
        if (inIdx >= 0 && inIdx < static_cast<int>(inPorts.size()))
            midiInPortBox_->setSelectedItemByIndex(static_cast<std::size_t>(inIdx));
    }
    if (midiOutPortBox_) {
        midiOutPortBox_->removeAllItems();
        for (const auto& name : outPorts)
            midiOutPortBox_->addItem(name);
        if (outIdx >= 0 && outIdx < static_cast<int>(outPorts.size()))
            midiOutPortBox_->setSelectedItemByIndex(static_cast<std::size_t>(outIdx));
    }
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
    // Poll modifier-aware key states each frame — robust against TGUI consuming key events.
    // Local controls use first-letter key, global uses Shift+same key.
    // Caps Lock acts as a "shift lock" for global modifier modes.
    bool rRaw = sf::Keyboard::isKeyPressed(sf::Keyboard::Key::R);
    bool zRaw = sf::Keyboard::isKeyPressed(sf::Keyboard::Key::Z);
    bool rawShiftNow = sf::Keyboard::isKeyPressed(sf::Keyboard::Key::LShift)
                    || sf::Keyboard::isKeyPressed(sf::Keyboard::Key::RShift);
    bool capsLockActive = isCapsLockActive();

    bool shiftNow = rawShiftNow || capsLockActive;
    bool oRaw = sf::Keyboard::isKeyPressed(sf::Keyboard::Key::O);
    bool gRaw = sf::Keyboard::isKeyPressed(sf::Keyboard::Key::G);
    bool xRaw = sf::Keyboard::isKeyPressed(sf::Keyboard::Key::X);
    bool cRaw = sf::Keyboard::isKeyPressed(sf::Keyboard::Key::C);

    bool rNow = rRaw && !shiftNow;         // local rotation
    bool globalRotationNow = rRaw && shiftNow;
    bool zNow = zRaw && !shiftNow;         // local zoom
    bool globalZoomNow = zRaw && shiftNow;
    bool oNow = oRaw && !shiftNow;         // local opacity
    bool globalOpacityNow = oRaw && shiftNow;
    bool gNow = gRaw && !shiftNow;         // local audio gain
    bool globalAudioGainNow = gRaw && shiftNow;
    bool imgXfadeNow = xRaw && !shiftNow;
    bool globalImgXfadeNow = xRaw && shiftNow;
    bool sceneXfadeNow = cRaw && !shiftNow;
    bool globalSceneXfadeNow = cRaw && shiftNow;

    bool pNow = sf::Keyboard::isKeyPressed(sf::Keyboard::Key::P);
    bool mNow = sf::Keyboard::isKeyPressed(sf::Keyboard::Key::M);
    bool bNow = sf::Keyboard::isKeyPressed(sf::Keyboard::Key::B);
    bool kNow = sf::Keyboard::isKeyPressed(sf::Keyboard::Key::K);
    bool minusNow = sf::Keyboard::isKeyPressed(sf::Keyboard::Key::Hyphen);
    bool equalNow = sf::Keyboard::isKeyPressed(sf::Keyboard::Key::Equal);
    bool lBracketNow = sf::Keyboard::isKeyPressed(sf::Keyboard::Key::LBracket);
    bool rBracketNow = sf::Keyboard::isKeyPressed(sf::Keyboard::Key::RBracket);
    bool commaNow = sf::Keyboard::isKeyPressed(sf::Keyboard::Key::Comma);
    bool periodNow = sf::Keyboard::isKeyPressed(sf::Keyboard::Key::Period);
    bool leftNow = sf::Keyboard::isKeyPressed(sf::Keyboard::Key::Left);
    bool rightNow = sf::Keyboard::isKeyPressed(sf::Keyboard::Key::Right);
    bool upNow = sf::Keyboard::isKeyPressed(sf::Keyboard::Key::Up);
    bool downNow = sf::Keyboard::isKeyPressed(sf::Keyboard::Key::Down);

    if (shiftLockLabel_) {
        shiftLockLabel_->setText(std::string("Caps Lock: ") + (capsLockActive ? "On" : "Off"));
        shiftLockLabel_->getRenderer()->setTextColor(capsLockActive ? tgui::Color(255, 210, 80) : TEXT_DIM);
    }

    if (rNow != rKeyWas_) { rKeyWas_ = rNow; if (onRKey) onRKey(rNow); }
    if (zNow != zKeyWas_) { zKeyWas_ = zNow; if (onZKey) onZKey(zNow); }
    if (oNow != oKeyWas_) { oKeyWas_ = oNow; if (onOKey) onOKey(oNow); }
    if (gNow != gKeyWas_) { gKeyWas_ = gNow; if (onGKey) onGKey(gNow); }
    if (pNow != pKeyWas_) { pKeyWas_ = pNow; if (onPKey) onPKey(pNow); }
    if (imgXfadeNow != imgXfadeKeyWas_) {
        imgXfadeKeyWas_ = imgXfadeNow;
        if (onImgXfadeKey) onImgXfadeKey(imgXfadeNow);
    }
    if (sceneXfadeNow != sceneXfadeKeyWas_) {
        sceneXfadeKeyWas_ = sceneXfadeNow;
        if (onSceneXfadeKey) onSceneXfadeKey(sceneXfadeNow);
    }
    if (globalImgXfadeNow != globalImgXfadeKeyWas_) {
        globalImgXfadeKeyWas_ = globalImgXfadeNow;
        if (onGlobalImgXfadeKey) onGlobalImgXfadeKey(globalImgXfadeNow);
    }
    if (globalSceneXfadeNow != globalSceneXfadeKeyWas_) {
        globalSceneXfadeKeyWas_ = globalSceneXfadeNow;
        if (onGlobalSceneXfadeKey) onGlobalSceneXfadeKey(globalSceneXfadeNow);
    }
    if (globalOpacityNow != globalOpacityKeyWas_) {
        globalOpacityKeyWas_ = globalOpacityNow;
        if (onGlobalOpacityKey) onGlobalOpacityKey(globalOpacityNow);
    }
    if (globalAudioGainNow != globalAudioGainKeyWas_) {
        globalAudioGainKeyWas_ = globalAudioGainNow;
        if (onGlobalAudioGainKey) onGlobalAudioGainKey(globalAudioGainNow);
    }
    if (globalRotationNow != globalRotationKeyWas_) {
        globalRotationKeyWas_ = globalRotationNow;
        if (onGlobalRotationKey) onGlobalRotationKey(globalRotationNow);
    }
    if (globalZoomNow != globalZoomKeyWas_) {
        globalZoomKeyWas_ = globalZoomNow;
        if (onGlobalZoomKey) onGlobalZoomKey(globalZoomNow);
    }
    // B key: toggle bypass on rising edge (key-down event)
    if (bNow && !bKeyWas_) {
        audioBypassed_ = !audioBypassed_;
        if (onBKey) onBKey(audioBypassed_);
    }
    bKeyWas_ = bNow;

    // K key: toggle LIF sonification on/off.
    if (kNow && !kKeyWas_) {
        if (onLIFToneToggle) onLIFToneToggle();
    }
    kKeyWas_ = kNow;

    // M key: toggle LIF MIDI on/off.
    if (mNow && !mKeyWas_) {
        if (onLIFMidiToggle) onLIFMidiToggle();
    }
    mKeyWas_ = mNow;

    // Frequency range controls (edge-triggered).
    const float freqStep = rawShiftNow ? 80.0f : 20.0f;
    if (minusNow && !minusKeyWas_) {
        if (onLIFToneMinFreqNudge) onLIFToneMinFreqNudge(-freqStep);
    }
    if (equalNow && !equalKeyWas_) {
        if (onLIFToneMinFreqNudge) onLIFToneMinFreqNudge(freqStep);
    }
    if (lBracketNow && !lBracketKeyWas_) {
        if (onLIFToneMaxFreqNudge) onLIFToneMaxFreqNudge(-freqStep);
    }
    if (rBracketNow && !rBracketKeyWas_) {
        if (onLIFToneMaxFreqNudge) onLIFToneMaxFreqNudge(freqStep);
    }
    // Arrow pad mirrors frequency controls:
    // Left/Right = min freq down/up, Down/Up = max freq down/up.
    if (leftNow && !leftKeyWas_) {
        if (onLIFToneMinFreqNudge) onLIFToneMinFreqNudge(-freqStep);
    }
    if (rightNow && !rightKeyWas_) {
        if (onLIFToneMinFreqNudge) onLIFToneMinFreqNudge(freqStep);
    }
    if (downNow && !downKeyWas_) {
        if (onLIFToneMaxFreqNudge) onLIFToneMaxFreqNudge(-freqStep);
    }
    if (upNow && !upKeyWas_) {
        if (onLIFToneMaxFreqNudge) onLIFToneMaxFreqNudge(freqStep);
    }
    minusKeyWas_ = minusNow;
    equalKeyWas_ = equalNow;
    lBracketKeyWas_ = lBracketNow;
    rBracketKeyWas_ = rBracketNow;
    leftKeyWas_ = leftNow;
    rightKeyWas_ = rightNow;
    upKeyWas_ = upNow;
    downKeyWas_ = downNow;

    // Tempo controls (horizontal scan speed): comma slower, period faster.
    const float tempoStep = rawShiftNow ? 0.08f : 0.02f;
    if (commaNow && !commaKeyWas_) {
        if (onLIFToneTempoNudge) onLIFToneTempoNudge(-tempoStep);
    }
    if (periodNow && !periodKeyWas_) {
        if (onLIFToneTempoNudge) onLIFToneTempoNudge(tempoStep);
    }
    commaKeyWas_ = commaNow;
    periodKeyWas_ = periodNow;

    // Redraw pressure meter each frame
    drawPressureMeter();

    // Redraw audio meter each frame
    drawAudioMeter();
}

void ControlWindow::drawPressureMeter() {
    if (!pressureMeterCanvas_) return;
    auto& rt = pressureMeterCanvas_->getRenderTexture();
    pressureMeterCanvas_->clear(tgui::Color(12, 12, 24));

    const float w = static_cast<float>(pressureMeterCanvas_->getSize().x);
    const float h = static_cast<float>(pressureMeterCanvas_->getSize().y);

    sf::RectangleShape bg({w - 2.0f, h - 2.0f});
    bg.setPosition({1.0f, 1.0f});
    bg.setFillColor(sf::Color(30, 35, 55));
    rt.draw(bg);

    const float fillW = (w - 2.0f) * pressureNorm_;
    if (fillW > 1.0f) {
        uint8_t r = static_cast<uint8_t>(80.0f + pressureNorm_ * 160.0f);
        uint8_t g = static_cast<uint8_t>(170.0f - pressureNorm_ * 80.0f);
        uint8_t b = static_cast<uint8_t>(255.0f - pressureNorm_ * 180.0f);
        sf::RectangleShape fill({fillW, h - 2.0f});
        fill.setPosition({1.0f, 1.0f});
        fill.setFillColor(sf::Color(r, g, b, 230));
        rt.draw(fill);
    }

    pressureMeterCanvas_->display();
}

void ControlWindow::setAudioBands(const float* bands, int count, float rms) {
    int n = std::min(count, static_cast<int>(audioBands_.size()));
    for (int i = 0; i < n; ++i) audioBands_[i] = bands[i];
    audioRms_ = rms;
}

void ControlWindow::drawAudioMeter() {
    if (!audioMeterCanvas_) return;
    auto& rt = audioMeterCanvas_->getRenderTexture();
    // Distinct dark background so meter is always visible
    audioMeterCanvas_->clear(tgui::Color(12, 12, 24));

    const float cw     = static_cast<float>(audioMeterCanvas_->getSize().x);
    const float ch     = static_cast<float>(audioMeterCanvas_->getSize().y);
    const int   nBands = static_cast<int>(audioBands_.size()); // 8
    const float gap    = 3.0f;
    const float barW   = (cw - gap * (nBands + 1)) / nBands;

    for (int b = 0; b < nBands; ++b) {
        float x = gap + b * (barW + gap);

        // Empty slot background (always visible)
        sf::RectangleShape slot({barW, ch - 4.0f});
        slot.setPosition({x, 2.0f});
        slot.setFillColor(sf::Color(35, 35, 55));
        rt.draw(slot);

        float val  = audioBypassed_ ? 0.0f : audioBands_[b];
        float barH = val * (ch - 4.0f);
        if (barH < 1.0f) continue;

        // Colour: blue → green → yellow → red
        uint8_t cr, cg, cb;
        if (audioBypassed_) {
            cr = 60; cg = 60; cb = 60;
        } else if (val < 0.33f) {
            cr = 0;
            cg = static_cast<uint8_t>(val / 0.33f * 200.0f);
            cb = 220;
        } else if (val < 0.66f) {
            cr = static_cast<uint8_t>((val - 0.33f) / 0.33f * 255.0f);
            cg = 200;
            cb = 0;
        } else {
            cr = 255;
            cg = static_cast<uint8_t>((1.0f - val) * 200.0f);
            cb = 0;
        }

        sf::RectangleShape bar({barW, barH});
        bar.setPosition({x, ch - barH - 2.0f});
        bar.setFillColor(sf::Color(cr, cg, cb, 230));
        rt.draw(bar);
    }

    // RMS peak indicator line
    if (!audioBypassed_ && audioRms_ > 0.005f) {
        float peakY = ch - audioRms_ * (ch - 4.0f) - 2.0f;
        sf::RectangleShape line({cw - 2.0f, 2.0f});
        line.setPosition({1.0f, peakY});
        line.setFillColor(sf::Color(255, 255, 255, 180));
        rt.draw(line);
    }

    // Bypass: red bar across the top
    if (audioBypassed_) {
        sf::RectangleShape tick({cw - 4.0f, 4.0f});
        tick.setPosition({2.0f, 0.0f});
        tick.setFillColor(sf::Color(200, 60, 60, 200));
        rt.draw(tick);
    }

    audioMeterCanvas_->display();
}

void ControlWindow::render(const sf::Texture& compositePreview) {
    window_.clear(sf::Color(16, 16, 20));

    // Video monitor: letterboxed in right half.
    // Use view size (logical units) so positions are consistent with drawing coordinates.
    const sf::Vector2f viewSize = window_.getView().getSize();
    const float pw   = viewSize.x - static_cast<float>(leftColW_);
    const float ph   = viewSize.y;
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

