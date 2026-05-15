#include "MidiRouter.h"
#include <iostream>
#include <mutex>

MidiRouter::MidiRouter() {
    midiIn_ = std::make_unique<RtMidiIn>();
    midiOut_ = std::make_unique<RtMidiOut>();
}

MidiRouter::~MidiRouter() { closePort(); closeOutputPort(); }
std::vector<std::string> MidiRouter::outputPortNames() const {
    std::vector<std::string> names;
    unsigned int n = midiOut_->getPortCount();
    for (unsigned int i = 0; i < n; ++i)
        names.push_back(midiOut_->getPortName(i));
    return names;
}

bool MidiRouter::openOutputPort(int index) {
    closeOutputPort();
    try {
        midiOut_->openPort(static_cast<unsigned int>(index));
        return true;
    } catch (RtMidiError& e) {
        std::cerr << "[MidiRouter] Output: " << e.getMessage() << "\n";
        return false;
    }
}

void MidiRouter::closeOutputPort() {
    if (midiOut_->isPortOpen()) {
        midiOut_->closePort();
    }
}

bool MidiRouter::isOutputOpen() const { return midiOut_->isPortOpen(); }

void MidiRouter::sendNoteOn(int channel, int note, int velocity) {
    if (!isOutputOpen()) return;
    std::vector<unsigned char> msg = {
        static_cast<unsigned char>(0x90 | ((channel-1) & 0x0F)),
        static_cast<unsigned char>(note & 0x7F),
        static_cast<unsigned char>(velocity & 0x7F)
    };
    sendMessage(msg);
}

void MidiRouter::sendNoteOff(int channel, int note, int velocity) {
    if (!isOutputOpen()) return;
    std::vector<unsigned char> msg = {
        static_cast<unsigned char>(0x80 | ((channel-1) & 0x0F)),
        static_cast<unsigned char>(note & 0x7F),
        static_cast<unsigned char>(velocity & 0x7F)
    };
    sendMessage(msg);
}

void MidiRouter::sendCC(int channel, int cc, int value) {
    if (!isOutputOpen()) return;
    std::vector<unsigned char> msg = {
        static_cast<unsigned char>(0xB0 | ((channel-1) & 0x0F)),
        static_cast<unsigned char>(cc & 0x7F),
        static_cast<unsigned char>(value & 0x7F)
    };
    sendMessage(msg);
}

void MidiRouter::sendMessage(const std::vector<unsigned char>& msg) {
    if (!isOutputOpen()) return;
    try {
        midiOut_->sendMessage(&msg);
    } catch (RtMidiError& e) {
        std::cerr << "[MidiRouter] Output send error: " << e.getMessage() << "\n";
    }
}

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
        learnedKnobCcs_.fill(-1);
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
    } else if (status == 0xD0 && msg.size() >= 2) {
        ev.type     = MidiEvent::Type::ChannelPressure;
        ev.pressure = msg[1];
    }

    if (onAnyEvent) onAnyEvent(ev);

    if (ev.type == MidiEvent::Type::ChannelPressure) {
        if (onChannelPressure)
            onChannelPressure(ev.channel, ccToNorm(ev.pressure));
        return;
    }

    // ── Scene select ─────────────────────────────────────────────────────
    if (ev.type == MidiEvent::Type::NoteOn) {
        int sceneIdx = 0;
        if (noteToScene(ev.note, sceneIdx)) {
            if (onSceneSelect) onSceneSelect(sceneIdx);
            return;
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
    // 1) Prefer explicit fixed mapping from Constants.h.
    int fixed = ccToKnobIndex(cc);
    if (fixed >= 0) return fixed;

    // 2) If this CC was learned before, reuse it.
    for (int i = 0; i < NUM_KNOBS; ++i)
        if (learnedKnobCcs_[i] == cc)
            return i;

    // 3) Learn first unseen CC into next free knob slot.
    for (int i = 0; i < NUM_KNOBS; ++i) {
        if (learnedKnobCcs_[i] < 0) {
            learnedKnobCcs_[i] = cc;
            std::cerr << "[MidiRouter] Learned knob CC " << cc << " -> knob " << i << "\n";
            return i;
        }
    }

    // 4) Already learned 6 CCs and this one is unknown.
    return -1;
}

bool MidiRouter::noteToScene(int note, int& outSceneIdx) {
    int rel = note - NOTE_SCENE_BASE;
    if (rel < 0 || rel >= NUM_SCENES) return false;
    outSceneIdx = rel;
    return true;
}
