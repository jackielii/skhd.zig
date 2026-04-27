//! Minimal C bindings for the grabber binary.
//!
//! We hand-declare the IOKit / CoreFoundation symbols we need
//! instead of using `@cImport`. Zig 0.14's C translator chokes on
//! `iokit_common_err(return)` (a macro that uses `return` as a
//! parameter name) deep in `IOReturn.h`, and the resulting
//! `@compileError` sentinel is reachable through the module's
//! semantic analysis even when we don't name the macro ourselves.
//!
//! The ABI of these symbols is stable across macOS versions, so
//! mirroring the signatures here is straightforward and keeps the
//! grabber's surface narrow (no Cocoa, no Carbon, no ObjC runtime).

const std = @import("std");

// CoreFoundation opaque types — pointers to "Ref" types are how
// Apple frameworks model handles. We use anyopaque so we don't have
// to mirror the underlying structs.
pub const CFTypeRef = ?*anyopaque;
pub const CFAllocatorRef = ?*anyopaque;
pub const CFArrayRef = ?*anyopaque;
pub const CFArrayCallBacks = anyopaque;
pub const CFMutableArrayRef = ?*anyopaque;
pub const CFDictionaryRef = ?*anyopaque;
pub const CFDictionaryKeyCallBacks = anyopaque;
pub const CFDictionaryValueCallBacks = anyopaque;
pub const CFMutableDictionaryRef = ?*anyopaque;
pub const CFNumberRef = ?*anyopaque;
pub const CFStringRef = ?*anyopaque;
pub const CFRunLoopRef = ?*anyopaque;
pub const CFRunLoopTimerRef = ?*anyopaque;

pub const CFIndex = isize;
pub const CFTimeInterval = f64;
pub const CFAbsoluteTime = f64;
pub const Boolean = u8;

pub const CFNumberType = c_int;
pub const kCFNumberSInt32Type: CFNumberType = 3;

pub const CFStringEncoding = u32;
pub const kCFStringEncodingUTF8: CFStringEncoding = 0x08000100;

pub const CFRunLoopRunResult = c_int;
pub const kCFRunLoopRunFinished: CFRunLoopRunResult = 1;
pub const kCFRunLoopRunStopped: CFRunLoopRunResult = 2;
pub const kCFRunLoopRunTimedOut: CFRunLoopRunResult = 3;
pub const kCFRunLoopRunHandledSource: CFRunLoopRunResult = 4;

pub const CFRunLoopTimerCallBack = ?*const fn (CFRunLoopTimerRef, ?*anyopaque) callconv(.C) void;

pub const CFRunLoopTimerContext = extern struct {
    version: CFIndex = 0,
    info: ?*anyopaque = null,
    retain: ?*const fn (?*const anyopaque) callconv(.C) ?*const anyopaque = null,
    release: ?*const fn (?*const anyopaque) callconv(.C) void = null,
    copyDescription: ?*const fn (?*const anyopaque) callconv(.C) CFStringRef = null,
};

pub extern const kCFAllocatorDefault: CFAllocatorRef;
pub extern const kCFTypeArrayCallBacks: CFArrayCallBacks;
pub extern const kCFTypeDictionaryKeyCallBacks: CFDictionaryKeyCallBacks;
pub extern const kCFTypeDictionaryValueCallBacks: CFDictionaryValueCallBacks;
pub extern const kCFRunLoopDefaultMode: CFStringRef;

pub extern fn CFRelease(cf: CFTypeRef) void;
pub extern fn CFArrayCreateMutable(allocator: CFAllocatorRef, capacity: CFIndex, callbacks: *const CFArrayCallBacks) CFMutableArrayRef;
pub extern fn CFArrayAppendValue(array: CFMutableArrayRef, value: ?*const anyopaque) void;
pub extern fn CFDictionaryCreateMutable(
    allocator: CFAllocatorRef,
    capacity: CFIndex,
    keyCallBacks: *const CFDictionaryKeyCallBacks,
    valueCallBacks: *const CFDictionaryValueCallBacks,
) CFMutableDictionaryRef;
pub extern fn CFDictionarySetValue(dict: CFMutableDictionaryRef, key: ?*const anyopaque, value: ?*const anyopaque) void;
pub extern fn CFNumberCreate(allocator: CFAllocatorRef, type_: CFNumberType, valuePtr: *const anyopaque) CFNumberRef;
pub extern fn CFStringCreateWithCString(allocator: CFAllocatorRef, cstr: [*:0]const u8, encoding: CFStringEncoding) CFStringRef;
pub extern fn CFAbsoluteTimeGetCurrent() CFAbsoluteTime;

pub extern fn CFRunLoopGetCurrent() CFRunLoopRef;
pub extern fn CFRunLoopRunInMode(mode: CFStringRef, seconds: CFTimeInterval, returnAfterSourceHandled: Boolean) CFRunLoopRunResult;
pub extern fn CFRunLoopStop(rl: CFRunLoopRef) void;
pub extern fn CFRunLoopAddTimer(rl: CFRunLoopRef, timer: CFRunLoopTimerRef, mode: CFStringRef) void;
pub extern fn CFRunLoopTimerCreate(
    allocator: CFAllocatorRef,
    fireDate: CFAbsoluteTime,
    interval: CFTimeInterval,
    flags: u32,
    order: CFIndex,
    callout: CFRunLoopTimerCallBack,
    context: *CFRunLoopTimerContext,
) CFRunLoopTimerRef;

// IOKit / HID. IOHID*Ref are also opaque.
pub const IOReturn = c_int;
pub const kIOReturnSuccess: IOReturn = 0;
// Constants follow IOReturn.h: sys_iokit | sub_iokit_common (0xE0000000)
// + per-error sub-code. iokit_common_err(0x2c1), etc.
pub const kIOReturnNotPrivileged: IOReturn = @bitCast(@as(u32, 0xE00002C1));
pub const kIOReturnNotPermitted: IOReturn = @bitCast(@as(u32, 0xE00002E2));
pub const kIOReturnExclusiveAccess: IOReturn = @bitCast(@as(u32, 0xE00002C5));

pub const IOOptionBits = u32;
pub const kIOHIDOptionsTypeNone: IOOptionBits = 0x0;
pub const kIOHIDOptionsTypeSeizeDevice: IOOptionBits = 0x1;

pub const IOHIDManagerRef = ?*anyopaque;
pub const IOHIDDeviceRef = ?*anyopaque;
pub const IOHIDElementRef = ?*anyopaque;
pub const IOHIDValueRef = ?*anyopaque;

pub const IOHIDValueCallback = ?*const fn (
    context: ?*anyopaque,
    result: IOReturn,
    sender: ?*anyopaque,
    value: IOHIDValueRef,
) callconv(.C) void;

// Matching dictionary keys (string constants in IOHIDKeys.h).
pub const kIOHIDVendorIDKey: [*:0]const u8 = "VendorID";
pub const kIOHIDProductIDKey: [*:0]const u8 = "ProductID";

pub extern fn IOHIDManagerCreate(allocator: CFAllocatorRef, options: IOOptionBits) IOHIDManagerRef;
pub extern fn IOHIDManagerOpen(manager: IOHIDManagerRef, options: IOOptionBits) IOReturn;
pub extern fn IOHIDManagerClose(manager: IOHIDManagerRef, options: IOOptionBits) IOReturn;
pub extern fn IOHIDManagerSetDeviceMatchingMultiple(manager: IOHIDManagerRef, multiple: CFArrayRef) void;
pub extern fn IOHIDManagerRegisterInputValueCallback(manager: IOHIDManagerRef, callback: IOHIDValueCallback, context: ?*anyopaque) void;
pub extern fn IOHIDManagerScheduleWithRunLoop(manager: IOHIDManagerRef, runLoop: CFRunLoopRef, mode: CFStringRef) void;
pub extern fn IOHIDManagerUnscheduleFromRunLoop(manager: IOHIDManagerRef, runLoop: CFRunLoopRef, mode: CFStringRef) void;
pub extern fn IOHIDManagerCopyDevices(manager: IOHIDManagerRef) ?*anyopaque; // CFSetRef
pub extern fn CFSetGetCount(theSet: ?*anyopaque) CFIndex;

pub extern fn IOHIDValueGetElement(value: IOHIDValueRef) IOHIDElementRef;
pub extern fn IOHIDValueGetIntegerValue(value: IOHIDValueRef) CFIndex;
pub extern fn IOHIDElementGetUsagePage(element: IOHIDElementRef) u32;
pub extern fn IOHIDElementGetUsage(element: IOHIDElementRef) u32;

// libc bits (geteuid for the seize permission check).
pub extern fn geteuid() c_uint;

// stdio handle for setvbuf — when launchd redirects our stdout/stderr
// to a file, they go block-buffered; per-event log lines then aren't
// visible until the buffer fills. We force line-buffered (or
// unbuffered) at startup so debug logs land immediately.
pub const FILE = anyopaque;
pub extern var __stderrp: *FILE;
pub extern var __stdoutp: *FILE;
pub const _IONBF: c_int = 2;
pub extern fn setvbuf(stream: *FILE, buf: ?[*]u8, mode: c_int, size: usize) c_int;
