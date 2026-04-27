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
pub const CFRunLoopSourceRef = ?*anyopaque;
pub const CFFileDescriptorRef = ?*anyopaque;
pub const CFFileDescriptorNativeDescriptor = c_int;
pub const CFOptionFlags = u64;

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
pub extern fn CFRunLoopTimerInvalidate(timer: CFRunLoopTimerRef) void;
pub extern fn CFRunLoopAddSource(rl: CFRunLoopRef, source: CFRunLoopSourceRef, mode: CFStringRef) void;
pub extern fn CFRunLoopRemoveSource(rl: CFRunLoopRef, source: CFRunLoopSourceRef, mode: CFStringRef) void;

pub const CFFileDescriptorCallBack = ?*const fn (CFFileDescriptorRef, CFOptionFlags, ?*anyopaque) callconv(.C) void;

pub const CFFileDescriptorContext = extern struct {
    version: CFIndex = 0,
    info: ?*anyopaque = null,
    retain: ?*const fn (?*const anyopaque) callconv(.C) ?*const anyopaque = null,
    release: ?*const fn (?*const anyopaque) callconv(.C) void = null,
    copyDescription: ?*const fn (?*const anyopaque) callconv(.C) CFStringRef = null,
};

pub const kCFFileDescriptorReadCallBack: CFOptionFlags = 1 << 0;
pub const kCFFileDescriptorWriteCallBack: CFOptionFlags = 1 << 1;

pub extern fn CFFileDescriptorCreate(
    allocator: CFAllocatorRef,
    fd: CFFileDescriptorNativeDescriptor,
    closeOnInvalidate: Boolean,
    callout: CFFileDescriptorCallBack,
    context: *CFFileDescriptorContext,
) CFFileDescriptorRef;
pub extern fn CFFileDescriptorEnableCallBacks(f: CFFileDescriptorRef, callBackTypes: CFOptionFlags) void;
pub extern fn CFFileDescriptorCreateRunLoopSource(allocator: CFAllocatorRef, f: CFFileDescriptorRef, order: CFIndex) CFRunLoopSourceRef;
pub extern fn CFFileDescriptorInvalidate(f: CFFileDescriptorRef) void;
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
pub const kIOHIDPrimaryUsagePageKey: [*:0]const u8 = "PrimaryUsagePage";
pub const kIOHIDPrimaryUsageKey: [*:0]const u8 = "PrimaryUsage";
/// Per-device property: how long (in ms) Apple's keyboard firmware
/// waits before treating a caps_lock press as a toggle. Default ~150.
/// Setting it to 0 disables the firmware-level toggle entirely so
/// caps_lock acts like any other key under our seize. Same trick
/// Karabiner-Elements uses to suppress caps_lock-on-hold on built-in
/// MacBook keyboards.
pub const kIOHIDKeyboardCapsLockDelayOverrideKey: [*:0]const u8 = "HIDKeyboardCapsLockDelayOverride";

// HID usage pages / usages relevant to seize matching.
pub const kHIDPage_GenericDesktop: i32 = 0x01;
pub const kHIDUsage_GD_Keyboard: i32 = 0x06;

pub extern fn IOHIDManagerCreate(allocator: CFAllocatorRef, options: IOOptionBits) IOHIDManagerRef;
pub extern fn IOHIDManagerOpen(manager: IOHIDManagerRef, options: IOOptionBits) IOReturn;
pub extern fn IOHIDManagerClose(manager: IOHIDManagerRef, options: IOOptionBits) IOReturn;
pub extern fn IOHIDManagerSetDeviceMatchingMultiple(manager: IOHIDManagerRef, multiple: CFArrayRef) void;
pub extern fn IOHIDManagerRegisterInputValueCallback(manager: IOHIDManagerRef, callback: IOHIDValueCallback, context: ?*anyopaque) void;
pub extern fn IOHIDManagerScheduleWithRunLoop(manager: IOHIDManagerRef, runLoop: CFRunLoopRef, mode: CFStringRef) void;
pub extern fn IOHIDManagerUnscheduleFromRunLoop(manager: IOHIDManagerRef, runLoop: CFRunLoopRef, mode: CFStringRef) void;
pub extern fn IOHIDManagerCopyDevices(manager: IOHIDManagerRef) ?*anyopaque; // CFSetRef
pub extern fn CFSetGetCount(theSet: ?*anyopaque) CFIndex;
pub extern fn CFSetGetValues(theSet: ?*anyopaque, values: [*]?*const anyopaque) void;
pub extern fn IOHIDDeviceSetProperty(device: IOHIDDeviceRef, key: CFStringRef, property: CFTypeRef) Boolean;

pub extern fn IOHIDValueGetElement(value: IOHIDValueRef) IOHIDElementRef;
pub extern fn IOHIDValueGetIntegerValue(value: IOHIDValueRef) CFIndex;
pub extern fn IOHIDElementGetUsagePage(element: IOHIDElementRef) u32;
pub extern fn IOHIDElementGetUsage(element: IOHIDElementRef) u32;

// IOService / IOHIDSystem client. Used by HidSystem.zig to force
// caps_lock state off after Apple's MacBook keyboard firmware toggles
// it through a side channel that IOHIDManager seize doesn't capture.
pub const mach_port_t = u32;
pub const task_port_t = mach_port_t;
pub const io_object_t = mach_port_t;
pub const io_service_t = io_object_t;
pub const io_connect_t = io_object_t;

pub const kIOMainPortDefault: mach_port_t = 0;
// IOHIDSystem's user-client connect type for parameter access (the
// type used to call IOHIDSet/GetModifierLockState). Defined in
// <IOKit/hidsystem/IOHIDShared.h>.
pub const kIOHIDParamConnectType: u32 = 1;
// Selector for IOHIDSet/GetModifierLockState. From <IOKit/hidsystem/IOLLEvent.h>.
pub const NX_MODIFIERKEY_ALPHALOCK: c_int = 0;

// `mach_task_self()` is a macro expanding to this global; export it
// directly so we don't need a C wrapper.
pub extern var mach_task_self_: mach_port_t;

pub extern fn IOServiceMatching(name: [*:0]const u8) CFMutableDictionaryRef;
pub extern fn IOServiceGetMatchingService(masterPort: mach_port_t, matching: CFDictionaryRef) io_service_t;
pub extern fn IOServiceOpen(service: io_service_t, owningTask: task_port_t, type_: u32, connect: *io_connect_t) IOReturn;
pub extern fn IOServiceClose(connect: io_connect_t) IOReturn;
pub extern fn IOObjectRelease(object: io_object_t) IOReturn;
pub extern fn IOHIDSetModifierLockState(handle: io_connect_t, selector: c_int, state: u8) IOReturn;
pub extern fn IOHIDGetModifierLockState(handle: io_connect_t, selector: c_int, state: *u8) IOReturn;

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
