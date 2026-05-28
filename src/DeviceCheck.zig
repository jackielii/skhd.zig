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
const IOHIDDeviceRef = ?*anyopaque;

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
extern fn CFNumberGetValue(number: CFNumberRef, type_: CFNumberType, valuePtr: *anyopaque) u8;
extern fn CFStringCreateWithCString(allocator: CFAllocatorRef, cstr: [*:0]const u8, encoding: CFStringEncoding) CFStringRef;
extern fn CFStringGetCString(string: CFStringRef, buffer: [*]u8, bufferSize: CFIndex, encoding: CFStringEncoding) u8;
extern fn CFSetGetCount(theSet: ?*anyopaque) CFIndex;
extern fn CFSetGetValues(theSet: ?*anyopaque, values: [*]?*const anyopaque) void;

extern fn IOHIDManagerCreate(allocator: CFAllocatorRef, options: IOOptionBits) IOHIDManagerRef;
extern fn IOHIDManagerSetDeviceMatchingMultiple(manager: IOHIDManagerRef, multiple: CFArrayRef) void;
extern fn IOHIDManagerCopyDevices(manager: IOHIDManagerRef) ?*anyopaque;
extern fn IOHIDDeviceGetProperty(device: IOHIDDeviceRef, key: CFStringRef) ?*anyopaque;

const kIOHIDVendorIDKey: [*:0]const u8 = "VendorID";
const kIOHIDProductIDKey: [*:0]const u8 = "ProductID";
const kIOHIDProductKey: [*:0]const u8 = "Product";
/// IOKit usage match keys. We use the `Primary*` variants here for
/// consistency with `HidSeize.setMatches` and `Hidutil.buildMatching`,
/// so all three matching paths see the same set of devices for a given
/// (vendor, product). `Device*` would also work for matching but can
/// diverge on composite devices.
const kIOHIDPrimaryUsagePageKey: [*:0]const u8 = "PrimaryUsagePage";
const kIOHIDPrimaryUsageKey: [*:0]const u8 = "PrimaryUsage";

/// HID usage page 0x01 (Generic Desktop), usage 0x06 (Keyboard) —
/// the standard "this device is a keyboard" pair.
const usage_page_generic_desktop: i32 = 1;
const usage_keyboard: i32 = 6;

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

    const dict = CFDictionaryCreateMutable(kCFAllocatorDefault, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (dict == null) return false;
    defer CFRelease(dict);

    // FIFO-transport built-in keyboards don't expose VendorID/ProductID
    // in IOKit. Including them with value 0 requires the property to
    // *exist* on the device, so 0 devices match. Match by usage only
    // and confirm a VID-less keyboard exists.
    if (vendor != 0 or product != 0) {
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
    }

    // Match Primary* (not Device*) for consistency with HidSeize.setMatches
    // and Hidutil.buildMatching — composite devices can disagree on the
    // two key families.
    const up_key = CFStringCreateWithCString(kCFAllocatorDefault, kIOHIDPrimaryUsagePageKey, kCFStringEncodingUTF8);
    if (up_key == null) return false;
    defer CFRelease(up_key);
    const u_key = CFStringCreateWithCString(kCFAllocatorDefault, kIOHIDPrimaryUsageKey, kCFStringEncodingUTF8);
    if (u_key == null) return false;
    defer CFRelease(u_key);

    var page_val: i32 = usage_page_generic_desktop;
    var usage_val: i32 = usage_keyboard;
    const page_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &page_val);
    if (page_num == null) return false;
    defer CFRelease(page_num);
    const usage_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &usage_val);
    if (usage_num == null) return false;
    defer CFRelease(usage_num);

    CFDictionarySetValue(dict, up_key, page_num);
    CFDictionarySetValue(dict, u_key, usage_num);
    CFArrayAppendValue(dicts, dict);

    IOHIDManagerSetDeviceMatchingMultiple(manager, dicts);

    const matched = IOHIDManagerCopyDevices(manager) orelse return false;
    defer CFRelease(matched);
    const count = CFSetGetCount(matched);
    log.debug("vendor=0x{X:0>4} product=0x{X:0>4} → {d} match(es)", .{ vendor, product, count });

    if (vendor != 0 or product != 0) return count > 0;

    // For 0/0: broad match includes the VHIDD. Confirm at least one
    // matched device lacks a VendorID property (FIFO built-in keyboard).
    if (count <= 0) return false;
    const n: usize = @intCast(count);
    const buf = std.heap.c_allocator.alloc(?*const anyopaque, n) catch return false;
    defer std.heap.c_allocator.free(buf);
    CFSetGetValues(matched, buf.ptr);

    const vid_key = CFStringCreateWithCString(kCFAllocatorDefault, kIOHIDVendorIDKey, kCFStringEncodingUTF8);
    if (vid_key == null) return false;
    defer CFRelease(vid_key);

    for (buf) |ref_const| {
        const dev: IOHIDDeviceRef = @constCast(ref_const);
        if (IOHIDDeviceGetProperty(dev, vid_key) == null) return true;
    }
    return false;
}

/// Print every connected HID keyboard as a paste-ready `.device`
/// block, with the product name as a comment and a slugified default
/// alias the user is expected to rename. Used by `skhd --list-devices`
/// so config authors don't have to dig through `hidutil list` output
/// (which lists hundreds of SMC sensors alongside actual keyboards).
pub fn printKeyboardList(allocator: std.mem.Allocator) !void {
    const manager = IOHIDManagerCreate(kCFAllocatorDefault, 0) orelse return error.IOHIDManagerCreateFailed;
    defer CFRelease(manager);

    // Match dict: { DeviceUsagePage: 1, DeviceUsage: 6 } → keyboards only.
    const dicts = CFArrayCreateMutable(kCFAllocatorDefault, 1, &kCFTypeArrayCallBacks) orelse return error.OutOfMemory;
    defer CFRelease(dicts);
    const match = CFDictionaryCreateMutable(kCFAllocatorDefault, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse return error.OutOfMemory;
    defer CFRelease(match);

    const up_key = CFStringCreateWithCString(kCFAllocatorDefault, kIOHIDPrimaryUsagePageKey, kCFStringEncodingUTF8) orelse return error.OutOfMemory;
    defer CFRelease(up_key);
    const u_key = CFStringCreateWithCString(kCFAllocatorDefault, kIOHIDPrimaryUsageKey, kCFStringEncodingUTF8) orelse return error.OutOfMemory;
    defer CFRelease(u_key);

    var page_val: i32 = usage_page_generic_desktop;
    var usage_val: i32 = usage_keyboard;
    const page_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &page_val) orelse return error.OutOfMemory;
    defer CFRelease(page_num);
    const usage_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &usage_val) orelse return error.OutOfMemory;
    defer CFRelease(usage_num);

    CFDictionarySetValue(match, up_key, page_num);
    CFDictionarySetValue(match, u_key, usage_num);
    CFArrayAppendValue(dicts, match);

    IOHIDManagerSetDeviceMatchingMultiple(manager, dicts);

    const matched = IOHIDManagerCopyDevices(manager);
    if (matched == null) {
        printNoKeyboards();
        return;
    }
    defer CFRelease(matched);

    const count_signed = CFSetGetCount(matched);
    if (count_signed <= 0) {
        printNoKeyboards();
        return;
    }
    const count: usize = @intCast(count_signed);

    const refs = try allocator.alloc(?*const anyopaque, count);
    defer allocator.free(refs);
    CFSetGetValues(matched, refs.ptr);

    // Property keys reused across every device in the loop.
    const v_prop = CFStringCreateWithCString(kCFAllocatorDefault, kIOHIDVendorIDKey, kCFStringEncodingUTF8) orelse return error.OutOfMemory;
    defer CFRelease(v_prop);
    const p_prop = CFStringCreateWithCString(kCFAllocatorDefault, kIOHIDProductIDKey, kCFStringEncodingUTF8) orelse return error.OutOfMemory;
    defer CFRelease(p_prop);
    const name_prop = CFStringCreateWithCString(kCFAllocatorDefault, kIOHIDProductKey, kCFStringEncodingUTF8) orelse return error.OutOfMemory;
    defer CFRelease(name_prop);

    // Dedup by (vendor, product) — IOKit returns one entry per HID
    // interface, so keyboards that expose Consumer Control alongside
    // their main keyboard usage (e.g. HHKB) appear twice with the same
    // VID/PID. `.device` keys on (vendor, product) so the second hit
    // is meaningless to skhd.
    var seen: std.ArrayList(VendorProduct) = try .initCapacity(allocator, count);
    defer seen.deinit(allocator);

    std.debug.print(
        \\Connected HID keyboards. Copy a block into your skhdrc and
        \\rename the alias if you want a shorter name. Then reference
        \\it from .remap / tap-hold rules (e.g. `device: my_alias`).
        \\
        \\
    , .{});

    var printed: usize = 0;
    for (refs) |ref_const| {
        const dev: IOHIDDeviceRef = @constCast(ref_const);
        const vendor = readU32Prop(dev, v_prop) orelse 0;
        const product = readU32Prop(dev, p_prop) orelse 0;

        if (containsVendorProduct(seen.items, vendor, product)) continue;
        try seen.append(allocator, .{ .vendor = vendor, .product = product });

        var name_buf: [256]u8 = undefined;
        const name = readStringProp(dev, name_prop, &name_buf);
        const name_display = if (name.len > 0) name else "(unnamed keyboard)";

        var slug_buf: [64]u8 = undefined;
        const slug = slugify(&slug_buf, name);
        const alias = if (slug.len == 0) "my_keyboard" else slug;

        if (printed > 0) std.debug.print("\n", .{});
        printed += 1;

        std.debug.print(
            \\# {s}
            \\.device {s} {{
            \\  vendor:  0x{x:0>4},
            \\  product: 0x{x:0>4},
            \\}}
            \\
        , .{ name_display, alias, vendor, product });
    }

    if (printed == 0) {
        printNoKeyboards();
        return;
    }

    // Logitech receivers and similar composite devices advertise a
    // keyboard usage even for mice/trackballs, so the list can include
    // entries that aren't keyboards in the everyday sense. Mention it
    // so users don't get confused when they see their mouse here.
    std.debug.print(
        \\
        \\Note: any HID device that advertises Generic Desktop / Keyboard
        \\usage shows up — including receivers that route keyboard and
        \\pointer events through a single VID/PID (e.g. Logitech Unifying).
        \\
    , .{});
}

const VendorProduct = struct { vendor: u32, product: u32 };

fn containsVendorProduct(seen: []const VendorProduct, vendor: u32, product: u32) bool {
    for (seen) |s| {
        if (s.vendor == vendor and s.product == product) return true;
    }
    return false;
}

fn printNoKeyboards() void {
    std.debug.print(
        \\No HID keyboards detected.
        \\
        \\If you expected to see one, make sure the keyboard is connected
        \\and that nothing else is exclusively grabbing it. Some virtual
        \\keyboards may not advertise as Generic Desktop / Keyboard and
        \\won't show up here.
        \\
    , .{});
}

fn readU32Prop(device: IOHIDDeviceRef, key: CFStringRef) ?u32 {
    const num = IOHIDDeviceGetProperty(device, key) orelse return null;
    var v: i32 = 0;
    if (CFNumberGetValue(num, kCFNumberSInt32Type, &v) == 0) return null;
    if (v < 0) return null;
    return @intCast(v);
}

/// Read a CFString property into the caller's buffer. Returns the
/// slice into `buf`, or an empty slice when the property is missing
/// or the conversion fails. Slice is valid until `buf` is reused.
fn readStringProp(device: IOHIDDeviceRef, key: CFStringRef, buf: []u8) []const u8 {
    const str = IOHIDDeviceGetProperty(device, key) orelse return "";
    if (CFStringGetCString(str, buf.ptr, @intCast(buf.len), kCFStringEncodingUTF8) == 0) return "";
    const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..len];
}

/// Turn a product name like "Apple Internal Keyboard / Trackpad" into
/// "apple_internal_keyboard_trackpad" so users get a workable default
/// alias they can keep or rename. Non-alphanumeric runs collapse to a
/// single `_`, and trailing separators are trimmed. Non-ASCII bytes
/// are treated as separators (good enough for the common-case English
/// product names; users can rename if they want something else).
fn slugify(buf: []u8, name: []const u8) []const u8 {
    var out_len: usize = 0;
    var prev_sep = true; // suppresses a leading underscore
    for (name) |b| {
        const lower = std.ascii.toLower(b);
        const is_alnum = (lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9');
        if (is_alnum) {
            if (out_len >= buf.len) break;
            buf[out_len] = lower;
            out_len += 1;
            prev_sep = false;
        } else if (!prev_sep) {
            if (out_len >= buf.len) break;
            buf[out_len] = '_';
            out_len += 1;
            prev_sep = true;
        }
    }
    if (out_len > 0 and buf[out_len - 1] == '_') out_len -= 1;
    return buf[0..out_len];
}

test "slugify: common product names" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("apple_internal_keyboard_trackpad", slugify(&buf, "Apple Internal Keyboard / Trackpad"));
    try std.testing.expectEqualStrings("keychron_q1", slugify(&buf, "Keychron Q1"));
    try std.testing.expectEqualStrings("magic_keyboard_a1843", slugify(&buf, "  Magic Keyboard - A1843  "));
    try std.testing.expectEqualStrings("", slugify(&buf, "***"));
    try std.testing.expectEqualStrings("", slugify(&buf, ""));
}

test "slugify: truncation respects buffer bounds" {
    var buf: [8]u8 = undefined;
    // "hello_world" → "hello_wo" once truncated (trailing non-_ kept).
    try std.testing.expectEqualStrings("hello_wo", slugify(&buf, "Hello World"));
    // Trailing underscore after truncation must still be trimmed.
    try std.testing.expectEqualStrings("hello", slugify(&buf, "Hello ----"));
}
