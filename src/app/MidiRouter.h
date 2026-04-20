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
// Special note-on messages (latch while held):
//   NOTE_LAYER_OPACITY_MODE (C2=36)  → KnobMode::LayerLevel
//   NOTE_FX_AUDIO_MODE      (C#2=37) → KnobMode::FxAudio
//   (all other note-ons)             → KnobMode::FxParam + dispatch FX patch select

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

    // Called when a FX patch select note-on arrives.
    // fxLayerSlot = 0/1/2 (FX layers 1/3/5), patchId = patch to activate.
    std::function<void(int fxLayerSlot, FxPatchId patchId)> onFxSelect;

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
    // Map a note to an FX select (fxSlot, patchId); returns false if not an FX select note
    static bool noteToFxSelect(int note, int& outSlot, FxPatchId& outPatch);
};
