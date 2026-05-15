#pragma once
#include "Constants.h"
#include <RtMidi.h>
#include <functional>
#include <string>
#include <vector>
#include <memory>
#include <mutex>

// ── MidiRouter ───────────────────────────────────────────────────────────────
// Opens one MIDI input port and routes incoming messages according to the
// current KnobMode and the constant note/CC mappings in Constants.h.
//
// Controller layout (6 CCs per frame — exact CC numbers TBD by user):
//   CC_LAYER_KNOB_BASE + 0..5 → knob 0..5
//
// Special note-on messages:
//   NOTE_SCENE_BASE + 0..31 (C2=36 … G4=67) → scene select
//
// Mode switching is now via keyboard keys in the control window:
//   O held → KnobMode::LayerLevel (layer opacity)
//   G held → KnobMode::FxAudio    (audio gain)
//   R held → KnobMode::ImgRotate
//   Z held → KnobMode::ImgZoom

struct MidiEvent {
    enum class Type { NoteOn, NoteOff, CC, ChannelPressure, Other };
    Type     type     = Type::Other;
    int      channel  = 0;  // 1-based
    int      note     = 0;
    int      velocity = 0;
    int      cc       = 0;
    int      value    = 0;
    int      pressure = 0;
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

    // Called when a scene pad in the configured note window is pressed. sceneIdx 0–31.
    std::function<void(int sceneIdx)> onSceneSelect;

    // Called when KnobMode changes (mode-latch note pressed/released).
    std::function<void(KnobMode)> onModeChange;

    // Raw event callback for the MIDI monitor / debug display.
    std::function<void(const MidiEvent&)> onAnyEvent;

    // Called on channel pressure (aftertouch) updates. channel is 1-based.
    std::function<void(int channel, float normValue)> onChannelPressure;

    KnobMode currentMode() const { return mode_; }

    // ── MIDI output ─────────────────────────────────────────────
    // Returns list of available output port names.
    std::vector<std::string> outputPortNames() const;
    // Open output port by index. Returns false on error.
    bool openOutputPort(int index);
    void closeOutputPort();
    bool isOutputOpen() const;
    // Send a Note On message (channel 1-based, 0-15; velocity 0-127)
    void sendNoteOn(int channel, int note, int velocity);
    // Send a Note Off message
    void sendNoteOff(int channel, int note, int velocity=0);
    // Send a Control Change (CC) message
    void sendCC(int channel, int cc, int value);

private:
    std::unique_ptr<RtMidiIn> midiIn_;
    KnobMode mode_ = KnobMode::FxParam;
    std::array<int, NUM_KNOBS> learnedKnobCcs_ = {-1, -1, -1, -1, -1, -1};

    // Thread-safe ring buffer for callbacks from MIDI thread → main thread
    struct PendingEvent { std::vector<unsigned char> bytes; double deltaTime; };
    std::vector<PendingEvent> pending_;
    mutable std::mutex pendingMutex_;

    static void rtCallback(double dt, std::vector<unsigned char>* msg, void* ud);
    void processEvent(const std::vector<unsigned char>& msg);

    // Map a CC index to knob 0–5. Uses fixed mapping first, then learned mapping.
    int ccToKnob(int cc);
    // Map a note to a scene index 0–31; returns false if not a scene note
    static bool noteToScene(int note, int& outSceneIdx);

    std::unique_ptr<RtMidiOut> midiOut_;
    void sendMessage(const std::vector<unsigned char>& msg);
};
