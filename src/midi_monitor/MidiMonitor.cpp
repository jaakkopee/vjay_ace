#include "MidiMonitor.h"

#include <TGUI/Widgets/Button.hpp>
#include <TGUI/Widgets/ComboBox.hpp>
#include <TGUI/Widgets/Label.hpp>
#include <TGUI/Widgets/ListBox.hpp>
#include <TGUI/Widgets/Panel.hpp>
#include <TGUI/Widgets/ScrollablePanel.hpp>

#include <array>
#include <ctime>
#include <iomanip>
#include <sstream>

// ── MIDI message helpers ──────────────────────────────────────────────────────

static const char* statusName(unsigned char status) {
    switch (status & 0xF0) {
        case 0x80: return "Note Off";
        case 0x90: return "Note On";
        case 0xA0: return "Aftertouch";
        case 0xB0: return "CC";
        case 0xC0: return "Program";
        case 0xD0: return "Ch Pressure";
        case 0xE0: return "Pitch Bend";
        case 0xF0: return "SysEx/RT";
        default:   return "Unknown";
    }
}

static const char* noteNames[] = {
    "C","C#","D","D#","E","F","F#","G","G#","A","A#","B"
};

static std::string noteName(unsigned char note) {
    int oct = (note / 12) - 1;
    std::string n = noteNames[note % 12];
    return n + std::to_string(oct);
}

// ── MidiMonitor ───────────────────────────────────────────────────────────────

MidiMonitor::MidiMonitor()
    : window_(sf::VideoMode({800, 600}), "MIDI Monitor — vjay_ace")
    , gui_(window_)
{
    window_.setFramerateLimit(60);
    midiIn_ = std::make_unique<RtMidiIn>();
    buildGui();
    refreshPorts();
}

MidiMonitor::~MidiMonitor() {
    closePort();
}

// ── GUI construction ──────────────────────────────────────────────────────────

void MidiMonitor::buildGui() {
    // Top toolbar panel
    auto toolbar = tgui::Panel::create({"100%", "44px"});
    toolbar->setPosition(0, 0);
    toolbar->getRenderer()->setBackgroundColor(tgui::Color(30, 30, 35));
    gui_.add(toolbar, "toolbar");

    auto portLabel = tgui::Label::create("MIDI Port:");
    portLabel->setPosition(8, 12);
    portLabel->getRenderer()->setTextColor(tgui::Color::White);
    toolbar->add(portLabel);

    portCombo_ = tgui::ComboBox::create();
    portCombo_->setPosition(90, 7);
    portCombo_->setSize(340, 30);
    portCombo_->onItemSelect([this](const tgui::String& /*item*/) {
        int index = portCombo_->getSelectedItemIndex();
        if (index >= 0) openPort(index);
    });
    toolbar->add(portCombo_, "portCombo");

    refreshBtn_ = tgui::Button::create("Refresh");
    refreshBtn_->setPosition(440, 7);
    refreshBtn_->setSize(80, 30);
    refreshBtn_->onClick([this]() { refreshPorts(); });
    toolbar->add(refreshBtn_);

    clearBtn_ = tgui::Button::create("Clear");
    clearBtn_->setPosition(530, 7);
    clearBtn_->setSize(70, 30);
    clearBtn_->onClick([this]() {
        std::lock_guard<std::mutex> lock(logMutex_);
        eventLog_.clear();
        if (logBox_) logBox_->removeAllItems();
    });
    toolbar->add(clearBtn_);

    // Event log
    logBox_ = tgui::ListBox::create();
    logBox_->setPosition(0, 44);
    logBox_->setSize("100%", "100% - 44px");
    logBox_->setItemHeight(18);
    logBox_->getRenderer()->setBackgroundColor(tgui::Color(18, 18, 22));
    logBox_->getRenderer()->setTextColor(tgui::Color(200, 230, 200));
    logBox_->getRenderer()->setSelectedBackgroundColor(tgui::Color(40, 80, 60));
    gui_.add(logBox_, "logBox");
}

// ── Port management ───────────────────────────────────────────────────────────

void MidiMonitor::refreshPorts() {
    closePort();
    portNames_.clear();
    portCombo_->removeAllItems();

    unsigned int count = midiIn_->getPortCount();
    for (unsigned int i = 0; i < count; ++i) {
        std::string name = midiIn_->getPortName(i);
        portNames_.push_back(name);
        portCombo_->addItem(name);
    }

    if (count == 0) {
        portCombo_->addItem("(no MIDI ports found)");
    } else {
        portCombo_->setSelectedItemByIndex(0);
        openPort(0);
    }
}

void MidiMonitor::openPort(int index) {
    if (index < 0 || index >= static_cast<int>(portNames_.size())) return;
    closePort();

    try {
        midiIn_->openPort(static_cast<unsigned int>(index));
        midiIn_->ignoreTypes(false, false, false); // sysex, timing, active sensing
        midiIn_->setCallback(&MidiMonitor::midiCallback, this);
        currentPort_ = index;

        std::string msg = ">>> Opened: " + portNames_[index];
        appendEvent(msg);
    } catch (RtMidiError& e) {
        appendEvent("ERROR opening port: " + e.getMessage());
    }
}

void MidiMonitor::closePort() {
    if (midiIn_->isPortOpen()) {
        midiIn_->cancelCallback();
        midiIn_->closePort();
    }
    currentPort_ = -1;
}

// ── Event logging ─────────────────────────────────────────────────────────────

void MidiMonitor::appendEvent(const std::string& line) {
    std::lock_guard<std::mutex> lock(logMutex_);
    pending_.push_back(line);
}

void MidiMonitor::flushPendingEvents() {
    std::lock_guard<std::mutex> lock(logMutex_);
    while (!pending_.empty()) {
        std::string line = pending_.front();
        pending_.pop_front();

        eventLog_.push_back(line);
        if (eventLog_.size() > MAX_LOG_LINES)
            eventLog_.pop_front();

        logBox_->addItem(line);
        if (logBox_->getItemCount() > static_cast<std::size_t>(MAX_LOG_LINES))
            logBox_->removeItemByIndex(0);

        // auto-scroll to bottom
        logBox_->setSelectedItemByIndex(
            static_cast<std::size_t>(logBox_->getItemCount()) - 1);
        logBox_->deselectItem();
    }
}

// ── MIDI callback ─────────────────────────────────────────────────────────────

void MidiMonitor::midiCallback(double deltaTime,
                                std::vector<unsigned char>* message,
                                void* userData) {
    auto* self = static_cast<MidiMonitor*>(userData);
    if (!message || message->empty()) return;
    std::string line = self->formatMessage(deltaTime, *message);
    self->appendEvent(line);
}

std::string MidiMonitor::formatMessage(double deltaTime,
                                        const std::vector<unsigned char>& msg) {
    // Timestamp
    auto now = std::time(nullptr);
    auto* tm = std::localtime(&now);
    std::ostringstream ss;
    ss << std::put_time(tm, "%H:%M:%S");
    ss << std::fixed << std::setprecision(3);
    ss << "  dt=" << deltaTime << "s  ";

    if (msg.empty()) { ss << "<empty>"; return ss.str(); }

    unsigned char status = msg[0];
    int channel = (status & 0x0F) + 1;

    if ((status & 0xF0) == 0xF0) {
        // System messages — no channel
        ss << statusName(status);
        for (std::size_t i = 1; i < msg.size(); ++i)
            ss << "  " << static_cast<int>(msg[i]);
        return ss.str();
    }

    ss << "Ch" << std::setw(2) << channel << "  ";
    ss << std::setw(11) << std::left << statusName(status) << std::right;

    switch (status & 0xF0) {
        case 0x80: // Note Off
            if (msg.size() >= 3)
                ss << "  note=" << noteName(msg[1])
                   << " (" << static_cast<int>(msg[1]) << ")"
                   << "  vel=" << static_cast<int>(msg[2]);
            break;
        case 0x90: // Note On
            if (msg.size() >= 3)
                ss << "  note=" << noteName(msg[1])
                   << " (" << static_cast<int>(msg[1]) << ")"
                   << "  vel=" << static_cast<int>(msg[2]);
            break;
        case 0xA0: // Aftertouch
            if (msg.size() >= 3)
                ss << "  note=" << static_cast<int>(msg[1])
                   << "  pressure=" << static_cast<int>(msg[2]);
            break;
        case 0xB0: // CC
            if (msg.size() >= 3)
                ss << "  cc=" << static_cast<int>(msg[1])
                   << "  val=" << static_cast<int>(msg[2]);
            break;
        case 0xC0: // Program Change
            if (msg.size() >= 2)
                ss << "  program=" << static_cast<int>(msg[1]);
            break;
        case 0xD0: // Channel Pressure
            if (msg.size() >= 2)
                ss << "  pressure=" << static_cast<int>(msg[1]);
            break;
        case 0xE0: // Pitch Bend
            if (msg.size() >= 3) {
                int bend = (static_cast<int>(msg[2]) << 7) | msg[1];
                ss << "  bend=" << bend << " (centre=8192)";
            }
            break;
        default:
            for (std::size_t i = 0; i < msg.size(); ++i)
                ss << "  " << std::hex << std::setw(2) << std::setfill('0')
                   << static_cast<int>(msg[i]);
    }

    return ss.str();
}

// ── Main loop ─────────────────────────────────────────────────────────────────

void MidiMonitor::run() {
    while (window_.isOpen()) {
        while (const std::optional<sf::Event> event = window_.pollEvent()) {
            gui_.handleEvent(*event);
            if (event->is<sf::Event::Closed>())
                window_.close();
            if (const auto* resized = event->getIf<sf::Event::Resized>()) {
                sf::FloatRect visibleArea(
                    sf::Vector2f(0.f, 0.f),
                    sf::Vector2f(static_cast<float>(resized->size.x),
                                 static_cast<float>(resized->size.y)));
                window_.setView(sf::View(visibleArea));
            }
        }

        flushPendingEvents();

        window_.clear(sf::Color(18, 18, 22));
        gui_.draw();
        window_.display();
    }
}
