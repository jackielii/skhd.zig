// Cross-checks the integer constants in src/c.zig against Apple's SDK
// headers. Compiled with `zig build check-c-constants` (no link, just
// -fsyntax-only); each line is a `_Static_assert(macro == zig_value)`
// — a mismatch is a compile error pointing at the offending name.
//
// Why this file exists: the agent's c.zig is hand-rolled (translate-c
// on Zig 0.16's Aro frontend doesn't grok Apple umbrella headers).
// Hand-rolling makes it easy to mistype enum values — most painfully,
// kEventAppFrontSwitched was once 'fwsw' (a FourCharCode) when it's
// actually integer 7, which silently mis-registered the front-app
// handler so process-specific bindings dispatched to the wrong app.
// This file ensures any future drift between c.zig and the SDK
// surfaces at build time, not at runtime.
//
// Pair this with the Zig test in src/tests.zig that re-parses this
// file and verifies the asserted values match c.zig (catches drift in
// the *other* direction — c.zig changing without updating this file).

#include <Carbon/Carbon.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreServices/CoreServices.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDLib.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <IOKit/hidsystem/ev_keymap.h>

// CoreFoundation
_Static_assert(kCFNumberSInt32Type            == 3,           "kCFNumberSInt32Type");
_Static_assert(kCFStringEncodingUTF8          == 0x08000100,  "kCFStringEncodingUTF8");
_Static_assert(kCFRunLoopRunFinished          == 1,           "kCFRunLoopRunFinished");
_Static_assert(kCFRunLoopRunStopped           == 2,           "kCFRunLoopRunStopped");
_Static_assert(kCFFileDescriptorReadCallBack  == (1 << 0),    "kCFFileDescriptorReadCallBack");

// CoreGraphics — event types
_Static_assert(kCGEventNull                   == 0,           "kCGEventNull");
_Static_assert(kCGEventLeftMouseDown          == 1,           "kCGEventLeftMouseDown");
_Static_assert(kCGEventLeftMouseUp            == 2,           "kCGEventLeftMouseUp");
_Static_assert(kCGEventRightMouseDown         == 3,           "kCGEventRightMouseDown");
_Static_assert(kCGEventRightMouseUp           == 4,           "kCGEventRightMouseUp");
_Static_assert(kCGEventKeyDown                == 10,          "kCGEventKeyDown");
_Static_assert(kCGEventKeyUp                  == 11,          "kCGEventKeyUp");
_Static_assert(kCGEventFlagsChanged           == 12,          "kCGEventFlagsChanged");
_Static_assert(kCGEventOtherMouseDown         == 25,          "kCGEventOtherMouseDown");
_Static_assert(kCGEventOtherMouseUp           == 26,          "kCGEventOtherMouseUp");
_Static_assert((unsigned)kCGEventTapDisabledByTimeout   == 0xFFFFFFFE, "kCGEventTapDisabledByTimeout");
_Static_assert((unsigned)kCGEventTapDisabledByUserInput == 0xFFFFFFFF, "kCGEventTapDisabledByUserInput");

// CoreGraphics — event fields
_Static_assert(kCGKeyboardEventKeycode        == 9,           "kCGKeyboardEventKeycode");
_Static_assert(kCGMouseEventButtonNumber      == 3,           "kCGMouseEventButtonNumber");
_Static_assert(kCGEventSourceUserData         == 42,          "kCGEventSourceUserData");

// CoreGraphics — mouse buttons
_Static_assert(kCGMouseButtonLeft             == 0,           "kCGMouseButtonLeft");
_Static_assert(kCGMouseButtonRight            == 1,           "kCGMouseButtonRight");

// CoreGraphics — event flags (modifier mask bits)
_Static_assert(kCGEventFlagMaskAlphaShift     == 0x10000,     "kCGEventFlagMaskAlphaShift");
_Static_assert(kCGEventFlagMaskShift          == 0x20000,     "kCGEventFlagMaskShift");
_Static_assert(kCGEventFlagMaskControl        == 0x40000,     "kCGEventFlagMaskControl");
_Static_assert(kCGEventFlagMaskAlternate      == 0x80000,     "kCGEventFlagMaskAlternate");
_Static_assert(kCGEventFlagMaskCommand        == 0x100000,    "kCGEventFlagMaskCommand");
_Static_assert(kCGEventFlagMaskHelp           == 0x400000,    "kCGEventFlagMaskHelp");
_Static_assert(kCGEventFlagMaskSecondaryFn    == 0x800000,    "kCGEventFlagMaskSecondaryFn");
_Static_assert(kCGEventFlagMaskNumericPad     == 0x200000,    "kCGEventFlagMaskNumericPad");
_Static_assert(kCGEventFlagMaskNonCoalesced   == 0x100,       "kCGEventFlagMaskNonCoalesced");

// CoreGraphics — event tap location/placement/options/source state
_Static_assert(kCGHIDEventTap                 == 0,           "kCGHIDEventTap");
_Static_assert(kCGSessionEventTap             == 1,           "kCGSessionEventTap");
_Static_assert(kCGAnnotatedSessionEventTap    == 2,           "kCGAnnotatedSessionEventTap");
_Static_assert(kCGHeadInsertEventTap          == 0,           "kCGHeadInsertEventTap");
_Static_assert(kCGEventTapOptionDefault       == 0,           "kCGEventTapOptionDefault");
_Static_assert(kCGEventSourceStateHIDSystemState == 1,        "kCGEventSourceStateHIDSystemState");

// FSEvents
_Static_assert(kFSEventStreamCreateFlagNoDefer    == 2,        "kFSEventStreamCreateFlagNoDefer");
_Static_assert(kFSEventStreamCreateFlagFileEvents == 16,       "kFSEventStreamCreateFlagFileEvents");
_Static_assert(kFSEventStreamEventIdSinceNow      == 0xFFFFFFFFFFFFFFFFULL, "kFSEventStreamEventIdSinceNow");

// Carbon — event handler param + type FourCharCodes
_Static_assert(kEventParamProcessID           == 0x70736E20,  "kEventParamProcessID");          // 'psn '
_Static_assert(typeProcessSerialNumber        == 0x70736E20,  "typeProcessSerialNumber");       // 'psn '

// Carbon — application event class + kind
_Static_assert(kEventClassApplication         == 0x6170706c,  "kEventClassApplication");        // 'appl'
_Static_assert(kEventAppFrontSwitched         == 7,           "kEventAppFrontSwitched");

// HIToolbox — Events.h: virtual keycodes (kVK_*)
_Static_assert(kVK_ANSI_A == 0x00, "kVK_ANSI_A");
_Static_assert(kVK_ANSI_S == 0x01, "kVK_ANSI_S");
_Static_assert(kVK_ANSI_D == 0x02, "kVK_ANSI_D");
_Static_assert(kVK_ANSI_F == 0x03, "kVK_ANSI_F");
_Static_assert(kVK_ANSI_H == 0x04, "kVK_ANSI_H");
_Static_assert(kVK_ANSI_G == 0x05, "kVK_ANSI_G");
_Static_assert(kVK_ANSI_Z == 0x06, "kVK_ANSI_Z");
_Static_assert(kVK_ANSI_X == 0x07, "kVK_ANSI_X");
_Static_assert(kVK_ANSI_C == 0x08, "kVK_ANSI_C");
_Static_assert(kVK_ANSI_V == 0x09, "kVK_ANSI_V");
_Static_assert(kVK_ANSI_B == 0x0B, "kVK_ANSI_B");
_Static_assert(kVK_ANSI_Q == 0x0C, "kVK_ANSI_Q");
_Static_assert(kVK_ANSI_W == 0x0D, "kVK_ANSI_W");
_Static_assert(kVK_ANSI_E == 0x0E, "kVK_ANSI_E");
_Static_assert(kVK_ANSI_R == 0x0F, "kVK_ANSI_R");
_Static_assert(kVK_ANSI_Y == 0x10, "kVK_ANSI_Y");
_Static_assert(kVK_ANSI_T == 0x11, "kVK_ANSI_T");
_Static_assert(kVK_ANSI_O == 0x1F, "kVK_ANSI_O");
_Static_assert(kVK_ANSI_U == 0x20, "kVK_ANSI_U");
_Static_assert(kVK_ANSI_I == 0x22, "kVK_ANSI_I");
_Static_assert(kVK_ANSI_P == 0x23, "kVK_ANSI_P");
_Static_assert(kVK_ANSI_L == 0x25, "kVK_ANSI_L");
_Static_assert(kVK_ANSI_J == 0x26, "kVK_ANSI_J");
_Static_assert(kVK_ANSI_K == 0x28, "kVK_ANSI_K");
_Static_assert(kVK_ANSI_N == 0x2D, "kVK_ANSI_N");
_Static_assert(kVK_ANSI_M == 0x2E, "kVK_ANSI_M");

_Static_assert(kVK_ANSI_1 == 0x12, "kVK_ANSI_1");
_Static_assert(kVK_ANSI_2 == 0x13, "kVK_ANSI_2");
_Static_assert(kVK_ANSI_3 == 0x14, "kVK_ANSI_3");
_Static_assert(kVK_ANSI_4 == 0x15, "kVK_ANSI_4");
_Static_assert(kVK_ANSI_5 == 0x17, "kVK_ANSI_5");
_Static_assert(kVK_ANSI_6 == 0x16, "kVK_ANSI_6");
_Static_assert(kVK_ANSI_7 == 0x1A, "kVK_ANSI_7");
_Static_assert(kVK_ANSI_8 == 0x1C, "kVK_ANSI_8");
_Static_assert(kVK_ANSI_9 == 0x19, "kVK_ANSI_9");
_Static_assert(kVK_ANSI_0 == 0x1D, "kVK_ANSI_0");

_Static_assert(kVK_ANSI_Equal        == 0x18, "kVK_ANSI_Equal");
_Static_assert(kVK_ANSI_Minus        == 0x1B, "kVK_ANSI_Minus");
_Static_assert(kVK_ANSI_RightBracket == 0x1E, "kVK_ANSI_RightBracket");
_Static_assert(kVK_ANSI_LeftBracket  == 0x21, "kVK_ANSI_LeftBracket");
_Static_assert(kVK_ANSI_Quote        == 0x27, "kVK_ANSI_Quote");
_Static_assert(kVK_ANSI_Semicolon    == 0x29, "kVK_ANSI_Semicolon");
_Static_assert(kVK_ANSI_Backslash    == 0x2A, "kVK_ANSI_Backslash");
_Static_assert(kVK_ANSI_Comma        == 0x2B, "kVK_ANSI_Comma");
_Static_assert(kVK_ANSI_Slash        == 0x2C, "kVK_ANSI_Slash");
_Static_assert(kVK_ANSI_Period       == 0x2F, "kVK_ANSI_Period");
_Static_assert(kVK_ANSI_Grave        == 0x32, "kVK_ANSI_Grave");

_Static_assert(kVK_Return        == 0x24, "kVK_Return");
_Static_assert(kVK_Tab           == 0x30, "kVK_Tab");
_Static_assert(kVK_Space         == 0x31, "kVK_Space");
_Static_assert(kVK_Delete        == 0x33, "kVK_Delete");
_Static_assert(kVK_Escape        == 0x35, "kVK_Escape");
_Static_assert(kVK_ForwardDelete == 0x75, "kVK_ForwardDelete");
_Static_assert(kVK_Help          == 0x72, "kVK_Help");
_Static_assert(kVK_Home          == 0x73, "kVK_Home");
_Static_assert(kVK_PageUp        == 0x74, "kVK_PageUp");
_Static_assert(kVK_End           == 0x77, "kVK_End");
_Static_assert(kVK_PageDown      == 0x79, "kVK_PageDown");

_Static_assert(kVK_LeftArrow  == 0x7B, "kVK_LeftArrow");
_Static_assert(kVK_RightArrow == 0x7C, "kVK_RightArrow");
_Static_assert(kVK_DownArrow  == 0x7D, "kVK_DownArrow");
_Static_assert(kVK_UpArrow    == 0x7E, "kVK_UpArrow");

_Static_assert(kVK_ISO_Section == 0x0A, "kVK_ISO_Section");

_Static_assert(kVK_F1  == 0x7A, "kVK_F1");
_Static_assert(kVK_F2  == 0x78, "kVK_F2");
_Static_assert(kVK_F3  == 0x63, "kVK_F3");
_Static_assert(kVK_F4  == 0x76, "kVK_F4");
_Static_assert(kVK_F5  == 0x60, "kVK_F5");
_Static_assert(kVK_F6  == 0x61, "kVK_F6");
_Static_assert(kVK_F7  == 0x62, "kVK_F7");
_Static_assert(kVK_F8  == 0x64, "kVK_F8");
_Static_assert(kVK_F9  == 0x65, "kVK_F9");
_Static_assert(kVK_F10 == 0x6D, "kVK_F10");
_Static_assert(kVK_F11 == 0x67, "kVK_F11");
_Static_assert(kVK_F12 == 0x6F, "kVK_F12");
_Static_assert(kVK_F13 == 0x69, "kVK_F13");
_Static_assert(kVK_F14 == 0x6B, "kVK_F14");
_Static_assert(kVK_F15 == 0x71, "kVK_F15");
_Static_assert(kVK_F16 == 0x6A, "kVK_F16");
_Static_assert(kVK_F17 == 0x40, "kVK_F17");
_Static_assert(kVK_F18 == 0x4F, "kVK_F18");
_Static_assert(kVK_F19 == 0x50, "kVK_F19");
_Static_assert(kVK_F20 == 0x5A, "kVK_F20");

// HIToolbox — UCKeyTranslate
_Static_assert(kUCKeyActionDisplay            == 3, "kUCKeyActionDisplay");
_Static_assert(kUCKeyTranslateNoDeadKeysMask  == 1, "kUCKeyTranslateNoDeadKeysMask");

// IOKit — IOReturn (sys_iokit | sub_iokit_common bits; signed int when read)
_Static_assert(kIOReturnSuccess         == 0,                      "kIOReturnSuccess");
_Static_assert(kIOReturnNotPrivileged   == (int)0xE00002C1,        "kIOReturnNotPrivileged");
_Static_assert(kIOReturnNotPermitted    == (int)0xE00002E2,        "kIOReturnNotPermitted");
_Static_assert(kIOReturnExclusiveAccess == (int)0xE00002C5,        "kIOReturnExclusiveAccess");

// IOKit — kIOMainPortDefault is `extern const mach_port_t` (a real
// symbol, not a #define) so _Static_assert can't see its value at
// compile time. We declare it as 0 in c.zig matching the SDK header
// initializer; if Apple changes the value we'd need a runtime check.

// IOKit — HID option bits
_Static_assert(kIOHIDOptionsTypeNone        == 0x0, "kIOHIDOptionsTypeNone");
_Static_assert(kIOHIDOptionsTypeSeizeDevice == 0x1, "kIOHIDOptionsTypeSeizeDevice");

// IOKit — hidsystem param connect type + modifier-lock selector
_Static_assert(kIOHIDParamConnectType    == 1, "kIOHIDParamConnectType");
_Static_assert(NX_MODIFIERKEY_ALPHALOCK   == 0, "NX_MODIFIERKEY_ALPHALOCK");

// IOKit — HID usage-page / generic-desktop usage
_Static_assert(kHIDPage_GenericDesktop == 0x01, "kHIDPage_GenericDesktop");
_Static_assert(kHIDUsage_GD_Keyboard   == 0x06, "kHIDUsage_GD_Keyboard");

// IOKit — system-defined media-key (NX_SYSDEFINED) types
_Static_assert(NX_SYSDEFINED                == 14, "NX_SYSDEFINED");
_Static_assert(NX_KEYTYPE_SOUND_UP          == 0,  "NX_KEYTYPE_SOUND_UP");
_Static_assert(NX_KEYTYPE_SOUND_DOWN        == 1,  "NX_KEYTYPE_SOUND_DOWN");
_Static_assert(NX_KEYTYPE_BRIGHTNESS_UP     == 2,  "NX_KEYTYPE_BRIGHTNESS_UP");
_Static_assert(NX_KEYTYPE_BRIGHTNESS_DOWN   == 3,  "NX_KEYTYPE_BRIGHTNESS_DOWN");
_Static_assert(NX_KEYTYPE_MUTE              == 7,  "NX_KEYTYPE_MUTE");
_Static_assert(NX_KEYTYPE_PLAY              == 16, "NX_KEYTYPE_PLAY");
_Static_assert(NX_KEYTYPE_NEXT              == 17, "NX_KEYTYPE_NEXT");
_Static_assert(NX_KEYTYPE_PREVIOUS          == 18, "NX_KEYTYPE_PREVIOUS");
_Static_assert(NX_KEYTYPE_FAST              == 19, "NX_KEYTYPE_FAST");
_Static_assert(NX_KEYTYPE_REWIND            == 20, "NX_KEYTYPE_REWIND");
_Static_assert(NX_KEYTYPE_ILLUMINATION_UP   == 21, "NX_KEYTYPE_ILLUMINATION_UP");
_Static_assert(NX_KEYTYPE_ILLUMINATION_DOWN == 22, "NX_KEYTYPE_ILLUMINATION_DOWN");

// IOKit — TCC HID access (Input Monitoring)
_Static_assert(kIOHIDRequestTypePostEvent   == 0, "kIOHIDRequestTypePostEvent");
_Static_assert(kIOHIDRequestTypeListenEvent == 1, "kIOHIDRequestTypeListenEvent");
_Static_assert(kIOHIDAccessTypeGranted      == 0, "kIOHIDAccessTypeGranted");
_Static_assert(kIOHIDAccessTypeDenied       == 1, "kIOHIDAccessTypeDenied");
_Static_assert(kIOHIDAccessTypeUnknown      == 2, "kIOHIDAccessTypeUnknown");

int main(void) { return 0; }
