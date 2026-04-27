//! Quick "is a HID device with this (vendor, product) connected?"
//! check, used by the agent to decide whether to forward block-form
//! `.remap` rules to the grabber.
//!
//! Without this, a config that targets `[device builtin]` on a Mac
//! Studio (no built-in keyboard) would still try to dial the grabber
//! socket and emit a warning when the grabber isn't installed —
//! forcing the user to install Karabiner-DriverKit-VirtualHIDDevice
//! and the grabber on a machine where they're never going to fire.
//!
//! Hand-rolled IOKit bindings rather than `@cImport(...IOHIDManager.h)`
//! because the C translator chokes on `iokit_common_err(return)` in
//! IOReturn.h on Zig 0.14 (same reason the grabber hand-rolls).

const std = @import("std");

const log = std.log.scoped(.device_check);

const CFAllocatorRef = ?*anyopaque;
const CFArrayRef = ?*anyopaque;
const CFArrayCallBacks = anyopaque;
const CFMutableArrayRef = ?*anyopaque;
const CFDictionaryRef = ?*anyopaque;
const CFDictionaryKeyCallBacks = anyopaque;
const CFDictionaryValueCallBacks = anyopaque;
const CFMutableDictionaryRef = ?*anyopaque;
const CFNumberRef = ?*anyopaque;
const CFStringRef = ?*anyopaque;
const CFTypeRef = ?*anyopaque;
const CFIndex = isize;

const CFNumberType = c_int;
const kCFNumberSInt32Type: CFNumberType = 3;

const CFStringEncoding = u32;
const kCFStringEncodingUTF8: CFStringEncoding = 0x08000100;

const IOOptionBits = u32;
const IOReturn = c_int;
const kIOReturnSuccess: IOReturn = 0;

const IOHIDManagerRef = ?*anyopaque;

extern const kCFAllocatorDefault: CFAllocatorRef;
extern const kCFTypeArrayCallBacks: CFArrayCallBacks;
extern const kCFTypeDictionaryKeyCallBacks: CFDictionaryKeyCallBacks;
extern const kCFTypeDictionaryValueCallBacks: CFDictionaryValueCallBacks;

extern fn CFRelease(cf: CFTypeRef) void;
extern fn CFArrayCreateMutable(allocator: CFAllocatorRef, capacity: CFIndex, callbacks: *const CFArrayCallBacks) CFMutableArrayRef;
extern fn CFArrayAppendValue(array: CFMutableArrayRef, value: ?*const anyopaque) void;
extern fn CFDictionaryCreateMutable(allocator: CFAllocatorRef, capacity: CFIndex, keyCallBacks: *const CFDictionaryKeyCallBacks, valueCallBacks: *const CFDictionaryValueCallBacks) CFMutableDictionaryRef;
extern fn CFDictionarySetValue(dict: CFMutableDictionaryRef, key: ?*const anyopaque, value: ?*const anyopaque) void;
extern fn CFNumberCreate(allocator: CFAllocatorRef, type_: CFNumberType, valuePtr: *const anyopaque) CFNumberRef;
extern fn CFStringCreateWithCString(allocator: CFAllocatorRef, cstr: [*:0]const u8, encoding: CFStringEncoding) CFStringRef;
extern fn CFSetGetCount(theSet: ?*anyopaque) CFIndex;

extern fn IOHIDManagerCreate(allocator: CFAllocatorRef, options: IOOptionBits) IOHIDManagerRef;
extern fn IOHIDManagerSetDeviceMatchingMultiple(manager: IOHIDManagerRef, multiple: CFArrayRef) void;
extern fn IOHIDManagerCopyDevices(manager: IOHIDManagerRef) ?*anyopaque;

const kIOHIDVendorIDKey: [*:0]const u8 = "VendorID";
const kIOHIDProductIDKey: [*:0]const u8 = "ProductID";

/// True when at least one HID device matching `(vendor, product)` is
/// currently connected. False when the lookup failed too — callers
/// treat "unknown" the same as "absent" since the only consequence
/// is skipping a grabber dial that would warn anyway.
pub fn isPresent(vendor: u32, product: u32) bool {
    const manager = IOHIDManagerCreate(kCFAllocatorDefault, 0);
    if (manager == null) return false;
    defer CFRelease(manager);

    const dicts = CFArrayCreateMutable(kCFAllocatorDefault, 1, &kCFTypeArrayCallBacks);
    if (dicts == null) return false;
    defer CFRelease(dicts);

    const dict = CFDictionaryCreateMutable(kCFAllocatorDefault, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (dict == null) return false;
    defer CFRelease(dict);

    const v_key = CFStringCreateWithCString(kCFAllocatorDefault, kIOHIDVendorIDKey, kCFStringEncodingUTF8);
    if (v_key == null) return false;
    defer CFRelease(v_key);
    const p_key = CFStringCreateWithCString(kCFAllocatorDefault, kIOHIDProductIDKey, kCFStringEncodingUTF8);
    if (p_key == null) return false;
    defer CFRelease(p_key);

    var v: i32 = @intCast(vendor);
    var p: i32 = @intCast(product);
    const v_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &v);
    if (v_num == null) return false;
    defer CFRelease(v_num);
    const p_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &p);
    if (p_num == null) return false;
    defer CFRelease(p_num);

    CFDictionarySetValue(dict, v_key, v_num);
    CFDictionarySetValue(dict, p_key, p_num);
    CFArrayAppendValue(dicts, dict);

    IOHIDManagerSetDeviceMatchingMultiple(manager, dicts);

    const matched = IOHIDManagerCopyDevices(manager) orelse return false;
    defer CFRelease(matched);
    const count = CFSetGetCount(matched);
    log.debug("vendor=0x{X:0>4} product=0x{X:0>4} → {d} match(es)", .{ vendor, product, count });
    return count > 0;
}
