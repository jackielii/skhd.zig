//! Hand-rolled C bindings for the agent binary.
//!
//! Zig 0.16's translate-c can't handle Apple's umbrella headers
//! (Carbon.h, CoreServices.h, ApplicationServices.h, even most subframework
//! headers): subframework auto-discovery was dropped, `__attribute__((nullable))`
//! on `uuid_t` array typedefs trips a clang error, Apple block syntax `^`
//! confuses it, and ATSFont.h / MDItem.h have implicit-int issues. Rather
//! than maintain umbrella @cImport workarounds, we mirror the symbols we
//! actually use, same way `src/grabber/c.zig` already does.
//!
//! Callers do `const c = @import("c.zig");` and reach decls directly as
//! `c.CFRelease`, `c.kVK_ANSI_A`, etc. (No more `.c` indirection.)
//!
//! Signatures verified against:
//! - <CoreFoundation/CoreFoundation.h>
//! - <CoreGraphics/CoreGraphics.h>
//! - <CoreServices/CoreServices.h> (FSEvents)
//! - <Carbon/Carbon.h> (HIToolbox: Events.h, CarbonEvents{,Core}.h, TextInputSources.h)
//! - <ApplicationServices/ApplicationServices.h> (HIServices: Processes.h, AXUIElement.h)
//! - <IOKit/{IOKitLib,hid/IOHIDManager,hidsystem/IOHIDLib,hidsystem/ev_keymap}.h>
//! - <SystemConfiguration/SystemConfiguration.h>
//! - libc / posix headers per symbol comment
//! - <objc/objc.h>, <objc/runtime.h>
//!
//! Cached translate-c output from earlier successful builds was used as the
//! source of truth for struct layouts and prototypes.

const std = @import("std");

// =====================================================================
// libc / POSIX
// =====================================================================

pub const uid_t = u32;
pub const gid_t = u32;
pub const pid_t = i32;
pub const mode_t = u16;
pub const time_t = c_long;

// fcntl.h
pub const O_WRONLY: c_int = 0x0001;
pub const O_CREAT: c_int = 0x0200;
pub const O_APPEND: c_int = 0x0008;
pub extern fn open(path: [*:0]const u8, oflag: c_int, ...) c_int;

// stdio.h — Apple uses `__sFILE` named `__stderrp` / `__stdoutp` globals.
pub const FILE = anyopaque;
pub extern var __stderrp: *FILE;
pub extern var __stdoutp: *FILE;
pub const _IONBF: c_int = 2;
pub extern fn setvbuf(stream: *FILE, buf: ?[*]u8, mode: c_int, size: usize) c_int;

// unistd.h
pub extern fn close(fd: c_int) c_int;
pub extern fn dup2(fildes: c_int, fildes2: c_int) c_int;
pub extern fn fork() pid_t;
pub extern fn execvp(file: [*:0]const u8, argv: [*]const ?[*:0]const u8) c_int;
pub extern fn _exit(status: c_int) noreturn;
pub extern fn setsid() pid_t;
pub extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
pub extern fn geteuid() uid_t;
pub extern fn getuid() uid_t;
pub extern fn unlink(path: [*:0]const u8) c_int;
pub extern fn chmod(path: [*:0]const u8, mode: mode_t) c_int;

// sys/wait.h
pub extern fn waitpid(pid: pid_t, status: ?*c_int, options: c_int) pid_t;

// sys/sysctl.h. (We only call this via `std.c.sysctl` in service.zig,
// so we don't actually need our own decl, but listed in inventory.)

// signal.h
pub extern fn kill(pid: pid_t, sig: c_int) c_int;

// pwd.h
pub const passwd = extern struct {
    pw_name: ?[*:0]u8,
    pw_passwd: ?[*:0]u8,
    pw_uid: uid_t,
    pw_gid: gid_t,
    pw_change: time_t,
    pw_class: ?[*:0]u8,
    pw_gecos: ?[*:0]u8,
    pw_dir: ?[*:0]u8,
    pw_shell: ?[*:0]u8,
    pw_expire: time_t,
};
pub extern fn getpwuid(uid: uid_t) ?*passwd;

// =====================================================================
// CoreFoundation
// =====================================================================

pub const Boolean = u8;
pub const UInt8 = u8;
pub const SInt32 = i32;
pub const UInt32 = u32;
pub const SInt64 = i64;
pub const UInt64 = u64;
pub const Float64 = f64;

pub const OSStatus = SInt32;
pub const OSErr = i16;
pub const OSType = u32;
pub const ItemCount = c_ulong;
pub const ByteCount = c_ulong;

// Carbon's noErr = 0 (OSStatus / OSErr success).
pub const noErr: OSStatus = 0;

pub const CFTypeRef = ?*const anyopaque;
pub const CFTypeID = c_ulong;
pub const CFAllocatorRef = ?*anyopaque;
pub const CFArrayRef = ?*const anyopaque;
pub const CFMutableArrayRef = ?*anyopaque;
pub const CFDictionaryRef = ?*const anyopaque;
pub const CFMutableDictionaryRef = ?*anyopaque;
pub const CFNumberRef = ?*const anyopaque;
pub const CFStringRef = ?*const anyopaque;
pub const CFDataRef = ?*const anyopaque;
pub const CFMutableDataRef = ?*anyopaque;
pub const CFBooleanRef = ?*const anyopaque;
pub const CFRunLoopRef = ?*anyopaque;
pub const CFRunLoopMode = CFStringRef;
pub const CFRunLoopSourceRef = ?*anyopaque;
pub const CFRunLoopTimerRef = ?*anyopaque;
pub const CFFileDescriptorRef = ?*anyopaque;
pub const CFFileDescriptorNativeDescriptor = c_int;
pub const CFMachPortRef = ?*anyopaque;

pub const CFArrayCallBacks = anyopaque;
pub const CFDictionaryKeyCallBacks = anyopaque;
pub const CFDictionaryValueCallBacks = anyopaque;
pub const CFAllocatorRetainCallBack = ?*const fn (?*const anyopaque) callconv(.c) ?*const anyopaque;
pub const CFAllocatorReleaseCallBack = ?*const fn (?*const anyopaque) callconv(.c) void;
pub const CFAllocatorCopyDescriptionCallBack = ?*const fn (?*const anyopaque) callconv(.c) CFStringRef;

pub const CFIndex = c_long;
pub const CFTimeInterval = f64;
pub const CFAbsoluteTime = f64;
pub const CFOptionFlags = c_ulong;

pub const CFNumberType = c_long;
pub const kCFNumberSInt32Type: CFNumberType = 3;

pub const CFStringEncoding = u32;
pub const kCFStringEncodingUTF8: CFStringEncoding = 0x08000100;

pub const CFRunLoopRunResult = SInt32;
pub const kCFRunLoopRunFinished: CFRunLoopRunResult = 1;
pub const kCFRunLoopRunStopped: CFRunLoopRunResult = 2;

pub const UniChar = u16;
pub const UniCharCount = c_ulong;

pub extern const kCFAllocatorDefault: CFAllocatorRef;
pub extern const kCFTypeArrayCallBacks: CFArrayCallBacks;
pub extern const kCFCopyStringDictionaryKeyCallBacks: CFDictionaryKeyCallBacks;
pub extern const kCFTypeDictionaryKeyCallBacks: CFDictionaryKeyCallBacks;
pub extern const kCFTypeDictionaryValueCallBacks: CFDictionaryValueCallBacks;
pub extern const kCFRunLoopDefaultMode: CFStringRef;
pub extern const kCFRunLoopCommonModes: CFStringRef;
pub extern const kCFBooleanTrue: CFBooleanRef;
pub extern const kCFPreferencesAnyApplication: CFStringRef;

pub extern fn CFRelease(cf: CFTypeRef) void;
pub extern fn CFGetTypeID(cf: CFTypeRef) CFTypeID;
pub extern fn CFAbsoluteTimeGetCurrent() CFAbsoluteTime;

pub extern fn CFArrayCreateMutable(allocator: CFAllocatorRef, capacity: CFIndex, callbacks: *const CFArrayCallBacks) CFMutableArrayRef;
pub extern fn CFArrayAppendValue(array: CFMutableArrayRef, value: ?*const anyopaque) void;
pub extern fn CFArrayGetCount(array: CFArrayRef) CFIndex;
pub extern fn CFArrayGetValueAtIndex(array: CFArrayRef, idx: CFIndex) ?*const anyopaque;

pub extern fn CFDictionaryCreate(
    allocator: CFAllocatorRef,
    keys: [*]const ?*const anyopaque,
    values: [*]const ?*const anyopaque,
    numValues: CFIndex,
    keyCallBacks: *const CFDictionaryKeyCallBacks,
    valueCallBacks: *const CFDictionaryValueCallBacks,
) CFDictionaryRef;
pub extern fn CFDictionaryCreateMutable(
    allocator: CFAllocatorRef,
    capacity: CFIndex,
    keyCallBacks: *const CFDictionaryKeyCallBacks,
    valueCallBacks: *const CFDictionaryValueCallBacks,
) CFMutableDictionaryRef;
pub extern fn CFDictionarySetValue(dict: CFMutableDictionaryRef, key: ?*const anyopaque, value: ?*const anyopaque) void;

pub extern fn CFNumberCreate(allocator: CFAllocatorRef, type_: CFNumberType, valuePtr: *const anyopaque) CFNumberRef;

pub extern fn CFStringCreateWithCString(allocator: CFAllocatorRef, cstr: [*:0]const u8, encoding: CFStringEncoding) CFStringRef;
pub extern fn CFStringCreateWithBytes(allocator: CFAllocatorRef, bytes: [*]const u8, numBytes: CFIndex, encoding: CFStringEncoding, isExternalRepresentation: Boolean) CFStringRef;
pub extern fn CFStringCreateWithCharacters(allocator: CFAllocatorRef, chars: [*]const UniChar, numChars: CFIndex) CFStringRef;
pub extern fn CFStringGetLength(theString: CFStringRef) CFIndex;
pub extern fn CFStringGetCharacterAtIndex(theString: CFStringRef, idx: CFIndex) UniChar;
pub extern fn CFStringGetCString(theString: CFStringRef, buffer: [*]u8, bufferSize: CFIndex, encoding: CFStringEncoding) Boolean;
pub extern fn CFStringGetMaximumSizeForEncoding(length: CFIndex, encoding: CFStringEncoding) CFIndex;

pub extern fn CFDataGetBytePtr(theData: CFDataRef) [*]const UInt8;

pub extern fn CFBooleanGetTypeID() CFTypeID;
pub extern fn CFBooleanGetValue(boolean: CFBooleanRef) Boolean;

pub extern fn CFSetGetCount(theSet: ?*const anyopaque) CFIndex;

pub extern fn CFPreferencesCopyAppValue(key: CFStringRef, applicationID: CFStringRef) CFTypeRef;

// CFRunLoop
pub extern fn CFRunLoopGetCurrent() CFRunLoopRef;
pub extern fn CFRunLoopGetMain() CFRunLoopRef;
pub extern fn CFRunLoopRun() void;
pub extern fn CFRunLoopRunInMode(mode: CFRunLoopMode, seconds: CFTimeInterval, returnAfterSourceHandled: Boolean) CFRunLoopRunResult;
pub extern fn CFRunLoopStop(rl: CFRunLoopRef) void;
pub extern fn CFRunLoopAddSource(rl: CFRunLoopRef, source: CFRunLoopSourceRef, mode: CFRunLoopMode) void;
pub extern fn CFRunLoopRemoveSource(rl: CFRunLoopRef, source: CFRunLoopSourceRef, mode: CFRunLoopMode) void;
pub extern fn CFRunLoopAddTimer(rl: CFRunLoopRef, timer: CFRunLoopTimerRef, mode: CFRunLoopMode) void;

pub const CFRunLoopTimerContext = extern struct {
    version: CFIndex = 0,
    info: ?*anyopaque = null,
    retain: CFAllocatorRetainCallBack = null,
    release: CFAllocatorReleaseCallBack = null,
    copyDescription: CFAllocatorCopyDescriptionCallBack = null,
};
pub const CFRunLoopTimerCallBack = ?*const fn (CFRunLoopTimerRef, ?*anyopaque) callconv(.c) void;
pub extern fn CFRunLoopTimerCreate(
    allocator: CFAllocatorRef,
    fireDate: CFAbsoluteTime,
    interval: CFTimeInterval,
    flags: CFOptionFlags,
    order: CFIndex,
    callout: CFRunLoopTimerCallBack,
    context: *CFRunLoopTimerContext,
) CFRunLoopTimerRef;
pub extern fn CFRunLoopTimerInvalidate(timer: CFRunLoopTimerRef) void;

// CFFileDescriptor
pub const CFFileDescriptorContext = extern struct {
    version: CFIndex = 0,
    info: ?*anyopaque = null,
    retain: CFAllocatorRetainCallBack = null,
    release: CFAllocatorReleaseCallBack = null,
    copyDescription: CFAllocatorCopyDescriptionCallBack = null,
};
pub const CFFileDescriptorCallBack = ?*const fn (CFFileDescriptorRef, CFOptionFlags, ?*anyopaque) callconv(.c) void;
pub const kCFFileDescriptorReadCallBack: CFOptionFlags = 1 << 0;
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

// CFMachPort
pub extern fn CFMachPortCreateRunLoopSource(allocator: CFAllocatorRef, port: CFMachPortRef, order: CFIndex) CFRunLoopSourceRef;
pub extern fn CFMachPortInvalidate(port: CFMachPortRef) void;

// =====================================================================
// CoreGraphics — event tap + posting
// =====================================================================

pub const CGEventRef = ?*anyopaque;
pub const CGEventType = u32;
pub const CGEventFlags = u64;
pub const CGEventField = u32;
pub const CGEventMask = u64;
pub const CGEventTapProxy = ?*anyopaque;
pub const CGEventSourceRef = ?*anyopaque;
pub const CGEventSourceStateID = i32;
pub const CGEventSourceKeyboardType = u32;
pub const CGEventTapLocation = u32;
pub const CGEventTapPlacement = u32;
pub const CGEventTapOptions = u32;
pub const CGKeyCode = u16;
pub const CGCharCode = u16;
pub const CGMouseButton = u32;
pub const CGError = i32;

pub const CGPoint = extern struct {
    x: f64,
    y: f64,
};

pub const CGEventTapCallBack = ?*const fn (CGEventTapProxy, CGEventType, CGEventRef, ?*anyopaque) callconv(.c) CGEventRef;

// CGEvent type / field constants
pub const kCGEventNull: CGEventType = 0;
pub const kCGEventLeftMouseDown: CGEventType = 1;
pub const kCGEventLeftMouseUp: CGEventType = 2;
pub const kCGEventRightMouseDown: CGEventType = 3;
pub const kCGEventRightMouseUp: CGEventType = 4;
pub const kCGEventKeyDown: CGEventType = 10;
pub const kCGEventKeyUp: CGEventType = 11;
pub const kCGEventFlagsChanged: CGEventType = 12;
pub const kCGEventOtherMouseDown: CGEventType = 25;
pub const kCGEventOtherMouseUp: CGEventType = 26;
pub const kCGEventTapDisabledByTimeout: CGEventType = 0xFFFFFFFE;
pub const kCGEventTapDisabledByUserInput: CGEventType = 0xFFFFFFFF;

pub const kCGKeyboardEventKeycode: CGEventField = 9;
pub const kCGMouseEventButtonNumber: CGEventField = 3;
pub const kCGEventSourceUserData: CGEventField = 42;

pub const kCGMouseButtonLeft: CGMouseButton = 0;
pub const kCGMouseButtonRight: CGMouseButton = 1;

pub const kCGEventFlagMaskAlphaShift: CGEventFlags = 0x10000;
pub const kCGEventFlagMaskShift: CGEventFlags = 0x20000;
pub const kCGEventFlagMaskControl: CGEventFlags = 0x40000;
pub const kCGEventFlagMaskAlternate: CGEventFlags = 0x80000;
pub const kCGEventFlagMaskCommand: CGEventFlags = 0x100000;
pub const kCGEventFlagMaskHelp: CGEventFlags = 0x400000;
pub const kCGEventFlagMaskSecondaryFn: CGEventFlags = 0x800000;
pub const kCGEventFlagMaskNumericPad: CGEventFlags = 0x200000;
pub const kCGEventFlagMaskNonCoalesced: CGEventFlags = 0x100;

// CGEventTapLocation
pub const kCGHIDEventTap: CGEventTapLocation = 0;
pub const kCGSessionEventTap: CGEventTapLocation = 1;
pub const kCGAnnotatedSessionEventTap: CGEventTapLocation = 2;
// CGEventTapPlacement
pub const kCGHeadInsertEventTap: CGEventTapPlacement = 0;
// CGEventTapOptions
pub const kCGEventTapOptionDefault: CGEventTapOptions = 0;
// CGEventSourceStateID
pub const kCGEventSourceStateHIDSystemState: CGEventSourceStateID = 1;

pub extern fn CGEventCreate(source: CGEventSourceRef) CGEventRef;
pub extern fn CGEventCreateData(allocator: CFAllocatorRef, event: CGEventRef) CFDataRef;
pub extern fn CGEventCreateKeyboardEvent(source: CGEventSourceRef, virtualKey: CGKeyCode, keyDown: bool) CGEventRef;
pub extern fn CGEventCreateMouseEvent(source: CGEventSourceRef, mouseType: CGEventType, mouseCursorPosition: CGPoint, mouseButton: CGMouseButton) CGEventRef;
pub extern fn CGEventGetType(event: CGEventRef) CGEventType;
pub extern fn CGEventGetFlags(event: CGEventRef) CGEventFlags;
pub extern fn CGEventSetFlags(event: CGEventRef, flags: CGEventFlags) void;
pub extern fn CGEventGetIntegerValueField(event: CGEventRef, field: CGEventField) i64;
pub extern fn CGEventSetIntegerValueField(event: CGEventRef, field: CGEventField, value: i64) void;
pub extern fn CGEventGetLocation(event: CGEventRef) CGPoint;
pub extern fn CGEventKeyboardSetUnicodeString(event: CGEventRef, stringLength: UniCharCount, unicodeString: [*]const UniChar) void;
pub extern fn CGEventPost(tap: CGEventTapLocation, event: CGEventRef) void;
pub extern fn CGEventTapCreate(
    tap: CGEventTapLocation,
    place: CGEventTapPlacement,
    options: CGEventTapOptions,
    eventsOfInterest: CGEventMask,
    callback: CGEventTapCallBack,
    userInfo: ?*anyopaque,
) CFMachPortRef;
pub extern fn CGEventTapEnable(tap: CFMachPortRef, enable: bool) void;
pub extern fn CGEventTapIsEnabled(tap: CFMachPortRef) bool;
pub extern fn CGEventSourceCreate(stateID: CGEventSourceStateID) CGEventSourceRef;
pub extern fn CGEventSourceFlagsState(stateID: CGEventSourceStateID) CGEventFlags;
pub extern fn CGEnableEventStateCombining(combineState: bool) CGError;
pub extern fn CGSetLocalEventsSuppressionInterval(seconds: CFTimeInterval) CGError;
pub extern fn CGPostKeyboardEvent(keyChar: CGCharCode, virtualKey: CGKeyCode, keyDown: bool) CGError;

// =====================================================================
// FSEvents (CoreServices)
// =====================================================================

pub const FSEventStreamRef = ?*anyopaque;
pub const ConstFSEventStreamRef = ?*const anyopaque;
pub const FSEventStreamCreateFlags = UInt32;
pub const FSEventStreamEventFlags = UInt32;
pub const FSEventStreamEventId = UInt64;

pub const kFSEventStreamCreateFlagNoDefer: FSEventStreamCreateFlags = 2;
pub const kFSEventStreamCreateFlagFileEvents: FSEventStreamCreateFlags = 16;
pub const kFSEventStreamEventIdSinceNow: FSEventStreamEventId = 0xFFFFFFFFFFFFFFFF;

pub const FSEventStreamContext = extern struct {
    version: CFIndex = 0,
    info: ?*anyopaque = null,
    retain: CFAllocatorRetainCallBack = null,
    release: CFAllocatorReleaseCallBack = null,
    copyDescription: CFAllocatorCopyDescriptionCallBack = null,
};

pub const FSEventStreamCallback = ?*const fn (
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: ?*anyopaque,
    numEvents: usize,
    eventPaths: ?*anyopaque,
    eventFlags: [*c]const FSEventStreamEventFlags,
    eventIds: [*c]const FSEventStreamEventId,
) callconv(.c) void;

pub extern fn FSEventStreamCreate(
    allocator: CFAllocatorRef,
    callback: FSEventStreamCallback,
    context: [*c]FSEventStreamContext,
    pathsToWatch: CFArrayRef,
    sinceWhen: FSEventStreamEventId,
    latency: CFTimeInterval,
    flags: FSEventStreamCreateFlags,
) FSEventStreamRef;
pub extern fn FSEventStreamScheduleWithRunLoop(streamRef: FSEventStreamRef, runLoop: CFRunLoopRef, runLoopMode: CFStringRef) void;
pub extern fn FSEventStreamStart(streamRef: FSEventStreamRef) Boolean;
pub extern fn FSEventStreamStop(streamRef: FSEventStreamRef) void;
pub extern fn FSEventStreamInvalidate(streamRef: FSEventStreamRef) void;
pub extern fn FSEventStreamRelease(streamRef: FSEventStreamRef) void;

// =====================================================================
// HIServices — Process management (deprecated but still functional)
// =====================================================================

pub const ProcessSerialNumber = extern struct {
    highLongOfPSN: UInt32 = 0,
    lowLongOfPSN: UInt32 = 0,
};

pub extern fn GetFrontProcess(pPSN: *ProcessSerialNumber) OSErr;
pub extern fn CopyProcessName(psn: *const ProcessSerialNumber, name: *CFStringRef) OSStatus;

// =====================================================================
// HIServices — AXUIElement
// =====================================================================

pub extern const kAXTrustedCheckOptionPrompt: CFStringRef;
pub extern fn AXIsProcessTrusted() Boolean;
pub extern fn AXIsProcessTrustedWithOptions(options: CFDictionaryRef) Boolean;

// =====================================================================
// HIToolbox — Carbon Events Core (event handler installation)
// =====================================================================

pub const EventRef = ?*anyopaque;
pub const EventHandlerRef = ?*anyopaque;
pub const EventHandlerCallRef = ?*anyopaque;
pub const EventTargetRef = ?*anyopaque;

pub const EventTypeSpec = extern struct {
    eventClass: OSType = 0,
    eventKind: UInt32 = 0,
};

pub const EventHandlerProcPtr = ?*const fn (EventHandlerCallRef, EventRef, ?*anyopaque) callconv(.c) OSStatus;
pub const EventHandlerUPP = EventHandlerProcPtr;

pub extern fn InstallEventHandler(
    inTarget: EventTargetRef,
    inHandler: EventHandlerUPP,
    inNumTypes: ItemCount,
    inList: [*]const EventTypeSpec,
    inUserData: ?*anyopaque,
    outRef: ?*EventHandlerRef,
) OSStatus;
pub extern fn RemoveEventHandler(inHandlerRef: EventHandlerRef) OSStatus;
pub extern fn GetApplicationEventTarget() EventTargetRef;

pub const EventParamName = OSType;
pub const EventParamType = OSType;
// inBufferSize / outActualSize are ByteCount (c_ulong → 64-bit on arm64
// macOS). Declaring them as UInt32 leaves the upper 32 bits of the
// register unspecified at the AArch64 PCS level, and Apple's stdlib can
// read them — the call then fails or scribbles past outData.
pub extern fn GetEventParameter(
    inEvent: EventRef,
    inName: EventParamName,
    inDesiredType: EventParamType,
    outActualType: ?*EventParamType,
    inBufferSize: ByteCount,
    outActualSize: ?*ByteCount,
    outData: ?*anyopaque,
) OSStatus;

// FourCharCode 'psn ' for both the param name and type.
pub const kEventParamProcessID: EventParamName = 0x70736E20;
pub const typeProcessSerialNumber: EventParamType = 0x70736E20;

/// Apple ships InstallApplicationEventHandler as an inline shim around
/// `InstallEventHandler(GetApplicationEventTarget(), ...)`. We mirror it
/// here so call sites read the same as in Apple sample code.
pub inline fn InstallApplicationEventHandler(
    handler: EventHandlerUPP,
    numTypes: ItemCount,
    list: [*]const EventTypeSpec,
    userData: ?*anyopaque,
    outHandlerRef: ?*EventHandlerRef,
) OSStatus {
    return InstallEventHandler(GetApplicationEventTarget(), handler, numTypes, list, userData, outHandlerRef);
}

// Carbon application event class + kinds (from CarbonEvents.h).
// Classes are FourCharCodes; event kinds are plain integers within
// their class. kEventAppFrontSwitched is enum value 7 — using
// 'fwsw' here silently mis-registers the handler so it never fires.
pub const kEventClassApplication: OSType = 0x6170706c; // 'appl'
pub const kEventAppFrontSwitched: UInt32 = 7;

// =====================================================================
// HIToolbox — Events.h: virtual keycodes (kVK_*)
// =====================================================================

// ANSI letters
pub const kVK_ANSI_A: c_int = 0x00;
pub const kVK_ANSI_S: c_int = 0x01;
pub const kVK_ANSI_D: c_int = 0x02;
pub const kVK_ANSI_F: c_int = 0x03;
pub const kVK_ANSI_H: c_int = 0x04;
pub const kVK_ANSI_G: c_int = 0x05;
pub const kVK_ANSI_Z: c_int = 0x06;
pub const kVK_ANSI_X: c_int = 0x07;
pub const kVK_ANSI_C: c_int = 0x08;
pub const kVK_ANSI_V: c_int = 0x09;
pub const kVK_ANSI_B: c_int = 0x0B;
pub const kVK_ANSI_Q: c_int = 0x0C;
pub const kVK_ANSI_W: c_int = 0x0D;
pub const kVK_ANSI_E: c_int = 0x0E;
pub const kVK_ANSI_R: c_int = 0x0F;
pub const kVK_ANSI_Y: c_int = 0x10;
pub const kVK_ANSI_T: c_int = 0x11;
pub const kVK_ANSI_O: c_int = 0x1F;
pub const kVK_ANSI_U: c_int = 0x20;
pub const kVK_ANSI_I: c_int = 0x22;
pub const kVK_ANSI_P: c_int = 0x23;
pub const kVK_ANSI_L: c_int = 0x25;
pub const kVK_ANSI_J: c_int = 0x26;
pub const kVK_ANSI_K: c_int = 0x28;
pub const kVK_ANSI_N: c_int = 0x2D;
pub const kVK_ANSI_M: c_int = 0x2E;

// ANSI digits (top row)
pub const kVK_ANSI_1: c_int = 0x12;
pub const kVK_ANSI_2: c_int = 0x13;
pub const kVK_ANSI_3: c_int = 0x14;
pub const kVK_ANSI_4: c_int = 0x15;
pub const kVK_ANSI_5: c_int = 0x17;
pub const kVK_ANSI_6: c_int = 0x16;
pub const kVK_ANSI_7: c_int = 0x1A;
pub const kVK_ANSI_8: c_int = 0x1C;
pub const kVK_ANSI_9: c_int = 0x19;
pub const kVK_ANSI_0: c_int = 0x1D;

// ANSI punctuation
pub const kVK_ANSI_Equal: c_int = 0x18;
pub const kVK_ANSI_Minus: c_int = 0x1B;
pub const kVK_ANSI_RightBracket: c_int = 0x1E;
pub const kVK_ANSI_LeftBracket: c_int = 0x21;
pub const kVK_ANSI_Quote: c_int = 0x27;
pub const kVK_ANSI_Semicolon: c_int = 0x29;
pub const kVK_ANSI_Backslash: c_int = 0x2A;
pub const kVK_ANSI_Comma: c_int = 0x2B;
pub const kVK_ANSI_Slash: c_int = 0x2C;
pub const kVK_ANSI_Period: c_int = 0x2F;
pub const kVK_ANSI_Grave: c_int = 0x32;

// Editing / control
pub const kVK_Return: c_int = 0x24;
pub const kVK_Tab: c_int = 0x30;
pub const kVK_Space: c_int = 0x31;
pub const kVK_Delete: c_int = 0x33;
pub const kVK_Escape: c_int = 0x35;
pub const kVK_ForwardDelete: c_int = 0x75;
pub const kVK_Help: c_int = 0x72;
pub const kVK_Home: c_int = 0x73;
pub const kVK_PageUp: c_int = 0x74;
pub const kVK_End: c_int = 0x77;
pub const kVK_PageDown: c_int = 0x79;

// Arrows
pub const kVK_LeftArrow: c_int = 0x7B;
pub const kVK_RightArrow: c_int = 0x7C;
pub const kVK_DownArrow: c_int = 0x7D;
pub const kVK_UpArrow: c_int = 0x7E;

// ISO
pub const kVK_ISO_Section: c_int = 0x0A;

// F-keys
pub const kVK_F1: c_int = 0x7A;
pub const kVK_F2: c_int = 0x78;
pub const kVK_F3: c_int = 0x63;
pub const kVK_F4: c_int = 0x76;
pub const kVK_F5: c_int = 0x60;
pub const kVK_F6: c_int = 0x61;
pub const kVK_F7: c_int = 0x62;
pub const kVK_F8: c_int = 0x64;
pub const kVK_F9: c_int = 0x65;
pub const kVK_F10: c_int = 0x6D;
pub const kVK_F11: c_int = 0x67;
pub const kVK_F12: c_int = 0x6F;
pub const kVK_F13: c_int = 0x69;
pub const kVK_F14: c_int = 0x6B;
pub const kVK_F15: c_int = 0x71;
pub const kVK_F16: c_int = 0x6A;
pub const kVK_F17: c_int = 0x40;
pub const kVK_F18: c_int = 0x4F;
pub const kVK_F19: c_int = 0x50;
pub const kVK_F20: c_int = 0x5A;

// =====================================================================
// HIToolbox — TextInputSources (TIS*) + UCKeyTranslate
// =====================================================================

pub const TISInputSourceRef = ?*anyopaque;

pub extern const kTISPropertyUnicodeKeyLayoutData: CFStringRef;
pub extern fn TISCopyCurrentASCIICapableKeyboardLayoutInputSource() TISInputSourceRef;
pub extern fn TISGetInputSourceProperty(inputSource: TISInputSourceRef, propertyKey: CFStringRef) ?*anyopaque;

// UCKeyTranslate (Unicode Utilities)
pub const UInt16 = u16;
pub const UCKeyboardLayout = anyopaque;
pub const UCKeyAction = u16;
pub const UCKeyTranslateOptions = u32;

pub const kUCKeyActionDisplay: UCKeyAction = 3;
pub const kUCKeyTranslateNoDeadKeysMask: UCKeyTranslateOptions = 1;

pub extern fn UCKeyTranslate(
    keyLayoutPtr: ?*const UCKeyboardLayout,
    virtualKeyCode: UInt16,
    keyAction: UCKeyAction,
    modifierKeyState: UInt32,
    keyboardType: UInt32,
    keyTranslateOptions: UCKeyTranslateOptions,
    deadKeyState: *UInt32,
    maxStringLength: UniCharCount,
    actualStringLength: *UniCharCount,
    unicodeString: [*]UniChar,
) OSStatus;

// LMGetKbdType — actually a Carbon shim around `LMGetKbdLast()`. The
// real symbol exported from HIToolbox is `LMGetKbdType` itself; the
// header makes it inline in some SDK versions but it's always available
// as an exported function.
pub extern fn LMGetKbdType() UInt8;

// =====================================================================
// IOKit / IOHID
// =====================================================================

pub const mach_port_t = u32;
pub const task_port_t = mach_port_t;
pub const io_object_t = mach_port_t;
pub const io_service_t = io_object_t;
pub const io_connect_t = io_object_t;

pub const kIOMainPortDefault: mach_port_t = 0;

pub const IOReturn = c_int;
pub const kIOReturnSuccess: IOReturn = 0;
// IOReturn.h: sys_iokit | sub_iokit_common (0xE0000000) + sub-code.
pub const kIOReturnNotPrivileged: IOReturn = @bitCast(@as(u32, 0xE00002C1));
pub const kIOReturnNotPermitted: IOReturn = @bitCast(@as(u32, 0xE00002E2));
pub const kIOReturnExclusiveAccess: IOReturn = @bitCast(@as(u32, 0xE00002C5));

pub const IOOptionBits = u32;
pub const kIOHIDOptionsTypeNone: IOOptionBits = 0x0;
pub const kIOHIDOptionsTypeSeizeDevice: IOOptionBits = 0x1;

// IOHIDSystem connect type / selector for modifier lock state.
pub const kIOHIDParamConnectType: u32 = 1;
pub const NX_MODIFIERKEY_ALPHALOCK: c_int = 0;

// `mach_task_self()` is a macro expanding to this global.
pub extern var mach_task_self_: mach_port_t;

pub extern fn IOServiceMatching(name: [*:0]const u8) CFMutableDictionaryRef;
pub extern fn IOServiceGetMatchingService(masterPort: mach_port_t, matching: CFDictionaryRef) io_service_t;
pub extern fn IOServiceOpen(service: io_service_t, owningTask: task_port_t, type_: u32, connect: *io_connect_t) IOReturn;
pub extern fn IOServiceClose(connect: io_connect_t) IOReturn;
pub extern fn IOObjectRelease(object: io_object_t) IOReturn;
pub extern fn IOHIDSetModifierLockState(handle: io_connect_t, selector: c_int, state: Boolean) IOReturn;
pub extern fn IOHIDGetModifierLockState(handle: io_connect_t, selector: c_int, state: *Boolean) IOReturn;

// IOHIDManager
pub const IOHIDManagerRef = ?*anyopaque;
pub const IOHIDDeviceRef = ?*anyopaque;
pub const IOHIDElementRef = ?*anyopaque;
pub const IOHIDValueRef = ?*anyopaque;
pub const IOHIDValueCallback = ?*const fn (
    context: ?*anyopaque,
    result: IOReturn,
    sender: ?*anyopaque,
    value: IOHIDValueRef,
) callconv(.c) void;

pub const kIOHIDVendorIDKey: [*:0]const u8 = "VendorID";
pub const kIOHIDProductIDKey: [*:0]const u8 = "ProductID";
pub const kIOHIDPrimaryUsagePageKey: [*:0]const u8 = "PrimaryUsagePage";
pub const kIOHIDPrimaryUsageKey: [*:0]const u8 = "PrimaryUsage";
pub const kIOHIDKeyboardCapsLockDelayOverrideKey: [*:0]const u8 = "HIDKeyboardCapsLockDelayOverride";

pub const kHIDPage_GenericDesktop: i32 = 0x01;
pub const kHIDUsage_GD_Keyboard: i32 = 0x06;

pub extern fn IOHIDManagerCreate(allocator: CFAllocatorRef, options: IOOptionBits) IOHIDManagerRef;
pub extern fn IOHIDManagerOpen(manager: IOHIDManagerRef, options: IOOptionBits) IOReturn;
pub extern fn IOHIDManagerClose(manager: IOHIDManagerRef, options: IOOptionBits) IOReturn;
pub extern fn IOHIDManagerSetDeviceMatchingMultiple(manager: IOHIDManagerRef, multiple: CFArrayRef) void;
pub extern fn IOHIDManagerRegisterInputValueCallback(manager: IOHIDManagerRef, callback: IOHIDValueCallback, context: ?*anyopaque) void;
pub extern fn IOHIDManagerScheduleWithRunLoop(manager: IOHIDManagerRef, runLoop: CFRunLoopRef, mode: CFStringRef) void;
pub extern fn IOHIDManagerUnscheduleFromRunLoop(manager: IOHIDManagerRef, runLoop: CFRunLoopRef, mode: CFStringRef) void;
pub extern fn IOHIDManagerCopyDevices(manager: IOHIDManagerRef) ?*const anyopaque; // CFSetRef

pub extern fn IOHIDValueGetElement(value: IOHIDValueRef) IOHIDElementRef;
pub extern fn IOHIDValueGetIntegerValue(value: IOHIDValueRef) CFIndex;
pub extern fn IOHIDElementGetUsagePage(element: IOHIDElementRef) u32;
pub extern fn IOHIDElementGetUsage(element: IOHIDElementRef) u32;

// Private IOHIDEventSystemClient API (needed for caps-lock override).
pub const IOHIDEventSystemClientRef = ?*anyopaque;
pub const IOHIDServiceClientRef = ?*anyopaque;
pub extern fn IOHIDEventSystemClientCreateSimpleClient(allocator: CFAllocatorRef) IOHIDEventSystemClientRef;
pub extern fn IOHIDEventSystemClientCopyServices(client: IOHIDEventSystemClientRef) CFArrayRef;
pub extern fn IOHIDServiceClientSetProperty(service: IOHIDServiceClientRef, key: CFStringRef, property: CFTypeRef) Boolean;

// =====================================================================
// IOKit / hidsystem / ev_keymap.h — system-defined media keys
// =====================================================================
//
// NX_KEYTYPE_* are the second-level codes inside an NX_SYSDEFINED event
// payload (see CGEventGetIntegerValueField with NX_SYSDEFINED). Values
// from <IOKit/hidsystem/ev_keymap.h>.
pub const NX_SYSDEFINED: CGEventType = 14;

pub const NX_KEYTYPE_SOUND_UP: c_int = 0;
pub const NX_KEYTYPE_SOUND_DOWN: c_int = 1;
pub const NX_KEYTYPE_BRIGHTNESS_UP: c_int = 2;
pub const NX_KEYTYPE_BRIGHTNESS_DOWN: c_int = 3;
pub const NX_KEYTYPE_MUTE: c_int = 7;
pub const NX_KEYTYPE_PLAY: c_int = 16;
pub const NX_KEYTYPE_NEXT: c_int = 17;
pub const NX_KEYTYPE_PREVIOUS: c_int = 18;
pub const NX_KEYTYPE_FAST: c_int = 19;
pub const NX_KEYTYPE_REWIND: c_int = 20;
pub const NX_KEYTYPE_ILLUMINATION_UP: c_int = 21;
pub const NX_KEYTYPE_ILLUMINATION_DOWN: c_int = 22;

// =====================================================================
// SystemConfiguration
// =====================================================================

pub const SCDynamicStoreRef = ?*anyopaque;

pub extern fn SCDynamicStoreCopyConsoleUser(
    store: SCDynamicStoreRef,
    uid_out: ?*uid_t,
    gid_out: ?*gid_t,
) CFStringRef;

// =====================================================================
// objc runtime
// =====================================================================

pub const Class = ?*anyopaque;
pub const SEL = ?*anyopaque;
pub const id = ?*anyopaque;
pub const BOOL = i8;

pub extern fn objc_getClass(name: [*:0]const u8) Class;
pub extern fn sel_registerName(name: [*:0]const u8) SEL;

// =====================================================================
// Cocoa NSApplicationLoad — needed to wake up Cocoa from a non-bundled
// agent so AppKit's NSRunningApplication / NSWorkspace observers work.
// =====================================================================
pub extern fn NSApplicationLoad() void;

// =====================================================================
// IOHIDCheckAccess / IOHIDRequestAccess — Input Monitoring TCC API.
// Available since macOS 10.15. Linked via IOKit.
// =====================================================================

pub const IOHIDRequestType = u32;
pub const kIOHIDRequestTypePostEvent: IOHIDRequestType = 0;
pub const kIOHIDRequestTypeListenEvent: IOHIDRequestType = 1;

pub const IOHIDAccessType = u32;
pub const kIOHIDAccessTypeGranted: IOHIDAccessType = 0;
pub const kIOHIDAccessTypeDenied: IOHIDAccessType = 1;
pub const kIOHIDAccessTypeUnknown: IOHIDAccessType = 2;

pub extern fn IOHIDCheckAccess(requestType: IOHIDRequestType) IOHIDAccessType;
/// Like IOHIDCheckAccess but triggers the macOS Input Monitoring approval
/// dialog the first time the bundle hits it. Returns Apple's `Boolean`
/// (CoreFoundation: unsigned char). Available since macOS 10.15.
pub extern fn IOHIDRequestAccess(requestType: IOHIDRequestType) Boolean;
