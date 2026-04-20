#pragma once

#include <RtMidi.h>
#include <TGUI/TGUI.hpp>
#include <TGUI/Backend/SFML-Graphics.hpp>
#include <SFML/Graphics.hpp>

#include <string>
#include <vector>
#include <mutex>
#include <deque>
#include <memory>

class MidiMonitor {
public:
    MidiMonitor();
    ~MidiMonitor();

    void run();

private:
    // MIDI
    std::unique_ptr<RtMidiIn> midiIn_;
    int currentPort_ = -1;
    std::vector<std::string> portNames_;

    std::deque<std::string> eventLog_;
    std::mutex logMutex_;
    static constexpr std::size_t MAX_LOG_LINES = 500;

    // GUI
    sf::RenderWindow window_;
    tgui::Gui gui_;

    tgui::ComboBox::Ptr portCombo_;
    tgui::ListBox::Ptr logBox_;
    tgui::Button::Ptr refreshBtn_;
    tgui::Button::Ptr clearBtn_;

    // helpers
    void buildGui();
    void refreshPorts();
    void openPort(int index);
    void closePort();
    void appendEvent(const std::string& line);
    void flushPendingEvents();

    // RtMidi callback
    static void midiCallback(double deltaTime,
                             std::vector<unsigned char>* message,
                             void* userData);

    std::string formatMessage(double deltaTime,
                              const std::vector<unsigned char>& msg);

    // pending lines buffered from callback thread
    std::deque<std::string> pending_;
};
