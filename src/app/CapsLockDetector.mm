#include "CapsLockDetector.h"

#ifdef __APPLE__
#include <Cocoa/Cocoa.h>

bool isCapsLockActive() {
    NSUInteger flags = [[NSEvent class] modifierFlags];
    return (flags & NSEventModifierFlagCapsLock) != 0;
}
#else

bool isCapsLockActive() {
    return false;  // Placeholder for non-macOS systems
}
#endif
