#pragma once
#include "Constants.h"
#include <RtMidi.h>
#include <functional>
#include <string>
#include <vector>
#include <memory>

// ── MidiRouter ───────────────────────────────────────────────────────────────
// Opens one MIDI input port and routes incoming messages according to the
// current KnobMode and the constant note/CC mappings in Constants.h.
//
// Controller layout (6 CCs per frame — exact CC numbers TBD by user):
//   CC_LAYER_KNOB_BASE + 0..5 → knob 0..5
//
// Special note-on messages:
//   NOTE_SCENE_BASE + 0..15 (C2=36 … C#3=51) → scene select
//
// Mode switching is now via keyboard keys in the control window:
//   O held → KnobMode::LayerLevel (layer opacity)
//   G held → KnobMode::FxAudio    (audio gain)
//   R held → KnobMode::ImgRotate
//   Z held → KnobMode::ImgZoom

struct MidiEvent {
    enum class Type { NoteOn, NoteOff, CC, Other };
    Type     type     = Type::Other;
    int      channel  = 0;  // 1-based
    int      note     = 0;
    int      velocity = 0;
    int      cc       = 0;
    int      value    = 0;
};

class MidiRouter {
public:
    MidiRouter();
    ~MidiRouter();

    // Returns list of available port names.
    std::vector<std::string> portNames() const;

    // Open port by index. Returns false on error.
    bool openPort(int index);
    void closePort();
    bool isOpen() const;

    // Must be called each frame from the main thread.
    // Drains the thread-safe event queue and fires registered callbacks.
    void poll();

    // ── Callbacks (set by App) ────────────────────────────────────────────
    // Called when a knob (CC) changes value. knobIdx 0–5, normValue 0.0–1.0.
    std::function<void(int knobIdx, float normValue, KnobMode mode)> onKnob;

    // Called when a scene pad (D2–D#3) is pressed. sceneIdx 0–13.
    std::function<void(int sceneIdx)> onSceneSelect;

    // Called when KnobMode changes (mode-latch note pressed/released).
    std::function<void(KnobMode)> onModeChange;

    // Raw event callback for the MIDI monitor / debug display.
    std::function<void(const MidiEvent&)> onAnyEvent;

    KnobMode currentMode() const { return mode_; }

private:
    std::unique_ptr<RtMidiIn> midiIn_;
    KnobMode mode_ = KnobMode::FxParam;

    // Thread-safe ring buffer for callbacks from MIDI thread → main thread
    struct PendingEvent { std::vector<unsigned char> bytes; double deltaTime; };
    std::vector<PendingEvent> pending_;
    mutable std::mutex pendingMutex_;

    static void rtCallback(double dt, std::vector<unsigned char>* msg, void* ud);
    void processEvent(const std::vector<unsigned char>& msg);

    // Map a CC index to knob 0–5 (returns -1 if not a knob CC)
    static int ccToKnob(int cc);
    // Map a note to a scene index 0–13; returns false if not a scene note
    static bool noteToScene(int note, int& outSceneIdx);
};
