// Unified C imports for the project
pub usingnamespace @cImport({
    @cInclude("Carbon/Carbon.h");
    @cInclude("CoreServices/CoreServices.h");
    @cInclude("objc/objc.h");
    @cInclude("objc/runtime.h");
    @cInclude("unistd.h");
    @cInclude("pwd.h");
    @cInclude("sys/types.h");
    @cInclude("sys/wait.h");
    @cInclude("fcntl.h");
    @cInclude("IOKit/hidsystem/ev_keymap.h");
});

// Additional declarations
pub extern fn NSApplicationLoad() void;

// IOHIDCheckAccess + enums from <IOKit/hidsystem/IOHIDLib.h>. translate-c
// drops the function when @cInclude'd (likely the availability macro
// surrounding the prototype), so we mirror it here. Available since macOS
// 10.15; we target 13.0+ so it's always present. Linked via the IOKit
// framework already pulled in for DeviceCheck.zig.
pub const IOHIDRequestType = u32;
pub const kIOHIDRequestTypePostEvent: IOHIDRequestType = 0;
pub const kIOHIDRequestTypeListenEvent: IOHIDRequestType = 1;

pub const IOHIDAccessType = u32;
pub const kIOHIDAccessTypeGranted: IOHIDAccessType = 0;
pub const kIOHIDAccessTypeDenied: IOHIDAccessType = 1;
pub const kIOHIDAccessTypeUnknown: IOHIDAccessType = 2;

pub extern fn IOHIDCheckAccess(requestType: IOHIDRequestType) IOHIDAccessType;

// IOHIDRequestAccess is the *prompting* variant of IOHIDCheckAccess — calling
// it triggers the macOS Input Monitoring approval dialog the first time the
// bundle hits it, same way AXIsProcessTrustedWithOptions(prompt=true) does
// for Accessibility. Returns true if access is currently granted; false
// otherwise (whether the user denied, the prompt is pending, or this is a
// first-launch unknown state). Available since macOS 10.15.
//
// IOKit returns Apple's `Boolean` typedef (CoreFoundation: unsigned char,
// not C99 _Bool), so we declare the FFI return as `u8` for arch-portable
// marshalling and treat any non-zero value as success at the call site.
pub extern fn IOHIDRequestAccess(requestType: IOHIDRequestType) u8;
