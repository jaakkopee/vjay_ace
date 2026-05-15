#pragma once
#include "Constants.h"
#include <SFML/Graphics.hpp>
#include <TGUI/TGUI.hpp>
#include <TGUI/Backend/SFML-Graphics.hpp>
#include <TGUI/Backend/Renderer/SFML-Graphics/CanvasSFML.hpp>
#include <array>
#include <chrono>
#include <functional>
#include <string>
#include <vector>

// ── ControlWindow ─────────────────────────────────────────────────────────────
// Screen 1 — two-column layout:
//
//  LEFT HALF                         |  RIGHT HALF
//  SCENE: [fx patch name]            |
//  MODE:  [mode name]                |  Video monitor (composite preview)
//                                    |
//  [K0]    [K1]    [K2]              |
//  name0   name1   name2             |
//  0.00    0.00    0.00              |
//                                    |
//  [K3]    [K4]    [K5]              |
//  name3   name4   name5             |
//  0.00    0.00    0.00              |
//
// CCs: 3, 9, 12, 13, 14, 15
// O held → knobs = local layer opacities
// Shift+O held → knobs = global layer opacity override
// G held → knobs = local audio gain
// Shift+G held → knobs = global audio gain override
// X held → knobs = local image crossfade speed
// Shift+X held → knobs = global image crossfade speed override
// C held → knobs = local scene crossfade speed
// Shift+C held → knobs = global scene crossfade speed override
// Default → knobs = active FX patch params

class ControlWindow {
public:
    ControlWindow();

    void open(int displayX, int displayY, int width, int height);
    bool isOpen() const;
    void close();

    bool handleEvents();
    void update();
    void render(const sf::Texture& compositePreview);

    // ── State setters ───────────────────────────────────────────────────────
    // Update knob arc and value display (cc value 0-127).
    void setKnobValue(int knobIdx, int ccValue);

    // Update parameter name shown under a knob.
    void setKnobParamName(int knobIdx, const std::string& name);

    // Update topology name label shown below the value.
    void setKnobTopoName(int knobIdx, const std::string& name);

    // Update the scene (FX patch) name at top-left.
    void setSceneName(const std::string& name);

    // Update mode label.
    void setKnobMode(KnobMode mode);

    // Update LIF MIDI status label and button.
    void setLifMidiStatus(bool enabled, int channel, int baseNote);

    // Update MIDI port lists and active selection indexes.
    void setMidiPortLists(const std::vector<std::string>& inPorts,
                          int inIdx,
                          const std::vector<std::string>& outPorts,
                          int outIdx);

    // Fired when user drags a knob: knobIdx 0-5, normValue 0.0-1.0
    std::function<void(int knobIdx, float normValue)> onKnobDrag;

    // Fired when R is pressed/released without Shift (local rotation mode)
    std::function<void(bool pressed)> onRKey;

    // Fired when Shift+R is pressed/released (global rotation override mode)
    std::function<void(bool pressed)> onGlobalRotationKey;

    // Fired when Z is pressed/released without Shift (local zoom mode)
    std::function<void(bool pressed)> onZKey;

    // Fired when Shift+Z is pressed/released (global zoom override mode)
    std::function<void(bool pressed)> onGlobalZoomKey;

    // Fired when O is pressed/released without Shift (local opacity mode)
    std::function<void(bool pressed)> onOKey;

    // Fired when G is pressed/released without Shift (local audio gain mode)
    std::function<void(bool pressed)> onGKey;

    // Fired when the P key is pressed (true) or released (false) → ImgPan mode
    std::function<void(bool pressed)> onPKey;

    // Fired when X is pressed/released without Shift (local image xfade mode)
    std::function<void(bool pressed)> onImgXfadeKey;

    // Fired when C is pressed/released without Shift (local scene xfade mode)
    std::function<void(bool pressed)> onSceneXfadeKey;

    // Fired when Shift+X is pressed/released (global image xfade override)
    std::function<void(bool pressed)> onGlobalImgXfadeKey;

    // Fired when Shift+C is pressed/released (global scene xfade override)
    std::function<void(bool pressed)> onGlobalSceneXfadeKey;

    // Fired when Shift+O is pressed/released (global opacity override mode)
    std::function<void(bool pressed)> onGlobalOpacityKey;

    // Fired when Shift+G is pressed/released (global audio gain override mode)
    std::function<void(bool pressed)> onGlobalAudioGainKey;

    // Fired when the B key is toggled (true = bypassed, false = active)
    std::function<void(bool bypassed)> onBKey;

    // Experimental LIF sonification controls.
    std::function<void()> onLIFToneToggle;
    std::function<void(float delta)> onLIFToneTempoNudge;
    std::function<void(float deltaHz)> onLIFToneMinFreqNudge;
    std::function<void(float deltaHz)> onLIFToneMaxFreqNudge;

    // LIF MIDI controls.
    std::function<void()> onLIFMidiToggle;

    // Runtime MIDI port selection callbacks (selected port name).
    std::function<void(const std::string&)> onMidiInPortChanged;
    std::function<void(const std::string&)> onMidiOutPortChanged;

    // Update audio level meter (8 bands 0-1, rms 0-1). Called each frame.
    void setAudioBands(const float* bands, int count, float rms);

    // Update channel pressure meter (0-1).
    void setPressureNorm(float norm);

private:
    sf::RenderWindow window_;
    tgui::Gui        gui_;

    static constexpr int KNOB_SIZE = 80;

    struct KnobState {
        int                   ccValue    = 0;
        tgui::CanvasSFML::Ptr canvas;
        tgui::Label::Ptr      paramLabel;
        tgui::Label::Ptr      valueLabel;
        tgui::Label::Ptr      topoNameLabel;
    };
    std::array<KnobState, NUM_KNOBS> knobs_;

    tgui::Label::Ptr sceneLabel_;
    tgui::Label::Ptr modeLabel_;
    tgui::Label::Ptr shiftLockLabel_;
    tgui::Label::Ptr pressureLabel_;
    tgui::Panel::Ptr rightPanel_;
    int              leftColW_ = 0;

    struct DragState {
        bool  active  = false;
        int   knob    = -1;
        int   startCC = 0;
        float startY  = 0.0f;
    } drag_;

    // Key polling state (previous frame)
    bool rKeyWas_ = false;
    bool zKeyWas_ = false;
    bool oKeyWas_ = false;
    bool gKeyWas_ = false;
    bool pKeyWas_ = false;
    bool imgXfadeKeyWas_ = false;
    bool sceneXfadeKeyWas_ = false;
    bool globalImgXfadeKeyWas_ = false;
    bool globalSceneXfadeKeyWas_ = false;
    bool globalOpacityKeyWas_ = false;
    bool globalAudioGainKeyWas_ = false;
    bool globalRotationKeyWas_ = false;
    bool globalZoomKeyWas_ = false;
    bool mKeyWas_ = false;
    bool nKeyWas_ = false;
    bool bKeyWas_ = false;
    bool kKeyWas_ = false;
    bool minusKeyWas_ = false;
    bool equalKeyWas_ = false;
    bool lBracketKeyWas_ = false;
    bool rBracketKeyWas_ = false;
    bool commaKeyWas_ = false;
    bool periodKeyWas_ = false;
    bool leftKeyWas_ = false;
    bool rightKeyWas_ = false;
    bool upKeyWas_ = false;
    bool downKeyWas_ = false;
    bool audioBypassed_ = false;

    // Audio bands for meter drawing (8 bands + RMS)
    std::array<float, 8> audioBands_ = {};
    float audioRms_ = 0.0f;
    float pressureNorm_ = 0.0f;
    tgui::CanvasSFML::Ptr audioMeterCanvas_;
    tgui::CanvasSFML::Ptr pressureMeterCanvas_;
    tgui::Button::Ptr lifMidiToggleBtn_;
    tgui::Label::Ptr lifMidiStatusLabel_;
    tgui::Button::Ptr midiSettingsBtn_;
    tgui::Panel::Ptr midiSettingsPanel_;
    tgui::ComboBox::Ptr midiInPortBox_;
    tgui::ComboBox::Ptr midiOutPortBox_;
    bool midiSettingsExpanded_ = false;

    void buildGui(int width, int height);
    void drawKnob(int knobIdx);
    void drawPressureMeter();
    void drawAudioMeter();
    void onMousePressed(float x, float y);
    void onMouseReleased();
    void onMouseMoved(float x, float y);
};
