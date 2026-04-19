// Private CoreGraphics symbols used by VMMetalView to disable macOS global
// hotkeys (Spaces, Mission Control, etc.) while the VM has keyboard focus.
#ifndef cgs_private_h
#define cgs_private_h

#include <CoreGraphics/CoreGraphics.h>

typedef uint32_t CGSConnectionID;
typedef CF_ENUM(uint32_t, CGSGlobalHotKeyOperatingMode) {
    kCGSGlobalHotKeyOperatingModeEnable = 0,
    kCGSGlobalHotKeyOperatingModeDisable = 1,
};
extern CGSConnectionID CGSMainConnectionID(void);
extern CGError CGSSetGlobalHotKeyOperatingMode(CGSConnectionID connection, CGSGlobalHotKeyOperatingMode mode);

#endif
