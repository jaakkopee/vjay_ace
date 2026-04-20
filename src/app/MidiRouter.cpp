#include "MidiRouter.h"
#include <iostream>
#include <mutex>

MidiRouter::MidiRouter() {
    midiIn_ = std::make_unique<RtMidiIn>();
}

MidiRouter::~MidiRouter() { closePort(); }

std::vector<std::string> MidiRouter::portNames() const {
    std::vector<std::string> names;
    unsigned int n = midiIn_->getPortCount();
    for (unsigned int i = 0; i < n; ++i)
        names.push_back(midiIn_->getPortName(i));
    return names;
}

bool MidiRouter::openPort(int index) {
    closePort();
    try {
        midiIn_->openPort(static_cast<unsigned int>(index));
        midiIn_->ignoreTypes(false, false, false);
        midiIn_->setCallback(&MidiRouter::rtCallback, this);
        return true;
    } catch (RtMidiError& e) {
        std::cerr << "[MidiRouter] " << e.getMessage() << "\n";
        return false;
    }
}

void MidiRouter::closePort() {
    if (midiIn_->isPortOpen()) {
        midiIn_->cancelCallback();
        midiIn_->closePort();
    }
}

bool MidiRouter::isOpen() const { return midiIn_->isPortOpen(); }

// ── RtMidi callback (runs on MIDI thread) ────────────────────────────────────

void MidiRouter::rtCallback(double dt, std::vector<unsigned char>* msg, void* ud) {
    auto* self = static_cast<MidiRouter*>(ud);
    if (!msg || msg->empty()) return;
    std::lock_guard<std::mutex> lock(self->pendingMutex_);
    self->pending_.push_back({*msg, dt});
}

// ── poll (called from main thread each frame) ─────────────────────────────────

void MidiRouter::poll() {
    std::vector<PendingEvent> batch;
    {
        std::lock_guard<std::mutex> lock(pendingMutex_);
        batch.swap(pending_);
    }
    for (auto& ev : batch)
        processEvent(ev.bytes);
}

// ── message processor ────────────────────────────────────────────────────────

void MidiRouter::processEvent(const std::vector<unsigned char>& msg) {
    if (msg.empty()) return;

    MidiEvent ev;
    ev.channel = (msg[0] & 0x0F) + 1;
    unsigned char status = msg[0] & 0xF0;

    if (status == 0x90 && msg.size() >= 3 && msg[2] > 0) {
        ev.type     = MidiEvent::Type::NoteOn;
        ev.note     = msg[1];
        ev.velocity = msg[2];
    } else if ((status == 0x80) || (status == 0x90 && msg[2] == 0)) {
        ev.type = MidiEvent::Type::NoteOff;
        ev.note = msg[1];
    } else if (status == 0xB0 && msg.size() >= 3) {
        ev.type  = MidiEvent::Type::CC;
        ev.cc    = msg[1];
        ev.value = msg[2];
    }

    if (onAnyEvent) onAnyEvent(ev);

    // ── Mode latch ───────────────────────────────────────────────────────
    if (ev.type == MidiEvent::Type::NoteOn) {
        if (ev.note == NOTE_LAYER_OPACITY_MODE) {
            mode_ = KnobMode::LayerLevel;
            if (onModeChange) onModeChange(mode_);
            return;
        }
        if (ev.note == NOTE_FX_AUDIO_MODE) {
            mode_ = KnobMode::FxAudio;
            if (onModeChange) onModeChange(mode_);
            return;
        }
        // Scene select
        int sceneIdx = 0;
        if (noteToScene(ev.note, sceneIdx)) {
            if (onSceneSelect) onSceneSelect(sceneIdx);
            return;
        }
    }
    if (ev.type == MidiEvent::Type::NoteOff) {
        if (ev.note == NOTE_LAYER_OPACITY_MODE || ev.note == NOTE_FX_AUDIO_MODE) {
            mode_ = KnobMode::FxParam;
            if (onModeChange) onModeChange(mode_);
        }
    }

    // ── Knob (CC) routing ────────────────────────────────────────────────
    if (ev.type == MidiEvent::Type::CC) {
        int knob = ccToKnob(ev.cc);
        if (knob >= 0 && onKnob)
            onKnob(knob, ccToNorm(ev.value), mode_);
    }
}

// ── mapping helpers ───────────────────────────────────────────────────────────

int MidiRouter::ccToKnob(int cc) {
    return ccToKnobIndex(cc);
}

bool MidiRouter::noteToScene(int note, int& outSceneIdx) {
    int rel = note - NOTE_SCENE_BASE;
    if (rel < 0 || rel >= NUM_SCENES) return false;
    outSceneIdx = rel;
    return true;
}
