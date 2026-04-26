// Unified C imports for the project
pub usingnamespace @cImport({
    @cInclude("Carbon/Carbon.h");
    @cInclude("CoreServices/CoreServices.h");
    @cInclude("objc/objc.h");
    @cInclude("objc/runtime.h");
    @cInclude("unistd.h");
    @cInclude("sys/types.h");
    @cInclude("sys/wait.h");
    @cInclude("fcntl.h");
    @cInclude("IOKit/hidsystem/ev_keymap.h");
    // IOHIDManager / IOHIDDevice / IOHIDValue: user-space HID monitor used
    // by the .device feature to identify which keyboard sourced each
    // keystroke. Read-only — no device seize.
    @cInclude("IOKit/hid/IOHIDManager.h");
    @cInclude("IOKit/hid/IOHIDKeys.h");
});

// Additional declarations
pub extern fn NSApplicationLoad() void;
