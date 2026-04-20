#include "App.h"
#import  <Cocoa/Cocoa.h>

int main(int /*argc*/, char** /*argv*/) {
    // Cocoa requires NSApplication to be initialised before any window
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp activateIgnoringOtherApps:YES];

    App app;
    if (!app.init()) return 1;
    app.run();
    return 0;
}
