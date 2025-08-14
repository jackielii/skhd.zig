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
    @cInclude("IOKit/hid/IOHIDManager.h");
    @cInclude("IOKit/hid/IOHIDDevice.h");
    @cInclude("IOKit/hid/IOHIDKeys.h");
    @cInclude("IOKit/hid/IOHIDUsageTables.h");
});

// Additional declarations
pub extern fn NSApplicationLoad() void;

// IOKit functions that might not be in headers
pub extern fn IOHIDDeviceGetRegistryEntryID(device: *anyopaque) u64;
