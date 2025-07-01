// Unified C imports for the project
pub usingnamespace @cImport({
    @cInclude("Carbon/Carbon.h");
    @cInclude("CoreServices/CoreServices.h");
    @cInclude("objc/objc.h");
    @cInclude("objc/runtime.h");
});

// Additional declarations
pub extern fn NSApplicationLoad() void;
