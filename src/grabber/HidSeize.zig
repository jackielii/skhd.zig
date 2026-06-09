//! IOHIDManager-based seize for the grabber.
//!
//! Opens a set of (vendor, product) keyboards with
//! `kIOHIDOptionsTypeSeizeDevice`. While seized, those devices'
//! input events bypass the normal HID stack — only this process's
//! input value callback receives them. The grabber then either
//! transforms (D4: tap-hold) or passes them straight through to the
//! Karabiner virtual HID device (D3: this module).
//!
//! Requires root: `IOHIDDeviceOpen(seize)` returns
//! `kIOReturnNotPrivileged` for non-root callers.
//!
//! Thread model: callbacks fire on the CFRunLoop thread we schedule
//! against. The caller is expected to drive that run loop on the
//! main thread.

const std = @import("std");
const builtin = @import("builtin");

const c = @import("c.zig");

const log = std.log.scoped(.hid_seize);

pub const Match = struct {
    vendor: u32,
    product: u32,
};

/// Internal-bus transports an Apple FIFO/SPI built-in keyboard reports.
/// External keyboards are "USB" or "Bluetooth", so scoping the built-in
/// match to these keeps externals out. macOS reports the built-in as
/// "FIFO" on most Apple Silicon Macs and "SPI" on some — match both.
const builtin_transports = [_][:0]const u8{ "FIFO", "SPI" };

/// CoreFoundation-free description of an alias's device-matching, split
/// out so the (vendor,product) → match-keys decision is unit-testable
/// without a live IOHIDManager. `setMatches` turns this into the actual
/// CFDictionaries (always with the keyboard-usage constraint).
///
/// A `null` vendor/product is omitted from the dict. When `transports`
/// is non-empty, `setMatches` emits one dict per transport (the manager
/// OR-matches them) instead of a VID/PID dict.
const Predicate = struct {
    vendor: ?u32,
    product: ?u32,
    /// Transport strings to match (e.g. {"FIFO","SPI"}). Empty for an
    /// explicit external device, which matches on VID/PID instead.
    transports: []const [:0]const u8,
};

/// Decide what an alias matches.
///
/// A FIFO/SPI built-in keyboard (vendor==0 and product==0) exposes no
/// VendorID/ProductID in IOKit, so it can't be matched on VID/PID.
/// IOHIDManager device-matching also ignores the `Built-In` key, so we
/// scope the built-in to its internal-bus transports; external
/// USB/Bluetooth keyboards then never enter the match.
///
/// A real (vendor,product) alias targets that exact external device, so
/// it matches on VID/PID and sets no transport constraint.
fn matchPredicate(m: Match) Predicate {
    const is_fifo_builtin = m.vendor == 0 and m.product == 0;
    return .{
        .vendor = if (is_fifo_builtin) null else m.vendor,
        .product = if (is_fifo_builtin) null else m.product,
        .transports = if (is_fifo_builtin) &builtin_transports else &.{},
    };
}

/// One HID input value, decoded from `IOHIDValueRef`. Only what the
/// pass-through path actually needs.
pub const Event = struct {
    usage_page: u32,
    usage: u32,
    /// 1 for keydown / modifier set; 0 for keyup / modifier clear.
    /// Booleans abstract over IOHIDValueGetIntegerValue's CFIndex.
    pressed: bool,
};

pub const Callback = *const fn (ctx: ?*anyopaque, event: Event) void;

/// Singleton state. IOKit callbacks are C function pointers with no
/// closure capture, so they need to find their way back to whatever
/// owns the manager. We use one process-wide HidSeize anyway, so a
/// global is the simplest representation.
var instance: ?*Self = null;

allocator: std.mem.Allocator,
manager: c.IOHIDManagerRef,
callback: Callback,
callback_ctx: ?*anyopaque,
running: bool = false,
/// Open options actually applied to IOHIDManagerOpen. Tracked so
/// stop() can mirror the same options on close.
open_options: u32 = 0,
/// Owned copy of the matches passed to setMatches. Reused by
/// disableCapsLockDelayOnMatches to filter event-system services
/// to just the ones we seized.
owned_matches: []Match = &.{},
/// IORegistry entry IDs of the devices actually seized, captured at the
/// end of `start(.seize)`. The liveness watchdog re-enumerates the live
/// internal keyboards each tick and compares against this set; a
/// mismatch means a device re-enumerated under us (stale seize) and the
/// daemon must rebuild. Empty until the first successful seize.
seized_entry_ids: []u64 = &.{},

const Self = @This();

pub fn init(allocator: std.mem.Allocator, callback: Callback, callback_ctx: ?*anyopaque) !*Self {
    if (instance != null) return error.AlreadyInitialized;

    const manager = c.IOHIDManagerCreate(c.kCFAllocatorDefault, c.kIOHIDOptionsTypeNone);
    if (manager == null) return error.IOHIDManagerCreateFailed;
    errdefer c.CFRelease(manager);

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .manager = manager,
        .callback = callback,
        .callback_ctx = callback_ctx,
    };
    instance = self;
    return self;
}

pub fn deinit(self: *Self) void {
    if (self.running) self.stop();
    if (self.owned_matches.len > 0) self.allocator.free(self.owned_matches);
    if (self.seized_entry_ids.len > 0) self.allocator.free(self.seized_entry_ids);
    c.CFRelease(self.manager);
    instance = null;
    self.allocator.destroy(self);
}

/// Set one i32-valued key on a matching dict, creating and releasing
/// the transient CFString key and CFNumber value. No-ops if a CF
/// allocation fails (not expected for these tiny objects).
fn setMatchKey(dict: c.CFMutableDictionaryRef, key_cstr: [*:0]const u8, value: i32) void {
    const key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, key_cstr, c.kCFStringEncodingUTF8);
    if (key == null) return;
    defer c.CFRelease(key);
    var v: i32 = value;
    const num = c.CFNumberCreate(c.kCFAllocatorDefault, c.kCFNumberSInt32Type, &v);
    if (num == null) return;
    defer c.CFRelease(num);
    c.CFDictionarySetValue(dict, key, num);
}

/// Set one string-valued key on a matching dict (e.g. Transport="FIFO"),
/// creating and releasing the transient CFString key and value. `value`
/// must be a NUL-terminated UTF-8 literal.
fn setMatchStrKey(dict: c.CFMutableDictionaryRef, key_cstr: [*:0]const u8, value: [*:0]const u8) void {
    const key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, key_cstr, c.kCFStringEncodingUTF8);
    if (key == null) return;
    defer c.CFRelease(key);
    const val = c.CFStringCreateWithCString(c.kCFAllocatorDefault, value, c.kCFStringEncodingUTF8);
    if (val == null) return;
    defer c.CFRelease(val);
    c.CFDictionarySetValue(dict, key, val);
}

/// Create one keyboard-usage matching dict, add whichever of
/// vendor/product/transport are supplied, and append it to `dicts`. A
/// FIFO/SPI built-in alias contributes one dict per transport (no
/// VID/PID); an external alias contributes a single VID/PID dict.
fn appendMatchDict(
    dicts: c.CFMutableArrayRef,
    vendor: ?u32,
    product: ?u32,
    transport: ?[:0]const u8,
) !void {
    const dict = c.CFDictionaryCreateMutable(
        c.kCFAllocatorDefault,
        4,
        &c.kCFTypeDictionaryKeyCallBacks,
        &c.kCFTypeDictionaryValueCallBacks,
    );
    if (dict == null) return error.CFDictionaryCreateFailed;
    defer c.CFRelease(dict);

    if (vendor) |v| setMatchKey(dict, c.kIOHIDVendorIDKey, @intCast(v));
    if (product) |p| setMatchKey(dict, c.kIOHIDProductIDKey, @intCast(p));
    if (transport) |t| setMatchStrKey(dict, c.kIOHIDTransportKey, t.ptr);
    setMatchKey(dict, c.kIOHIDPrimaryUsagePageKey, c.kHIDPage_GenericDesktop);
    setMatchKey(dict, c.kIOHIDPrimaryUsageKey, c.kHIDUsage_GD_Keyboard);

    c.CFArrayAppendValue(dicts, dict);
}

/// Build a CFArray of dictionaries, one or more per match, and apply it
/// as the manager's matching filter. Must be called before `start`.
///
/// We deliberately constrain to (Generic Desktop / Keyboard) only.
/// Apple's built-in MacBook keyboard exposes other HID services on
/// the same (vendor, product) — Apple Vendor at (0xFF00, 0x0B) for
/// media keys, AppleMultitouchDevice at (0x0D, 0x0C) for the
/// trackpad, etc. Seizing those is either disallowed by the kernel
/// (`kIOReturnExclusiveAccess`) or breaks pointer/media input. By
/// matching the keyboard service alone, the media-key service emits
/// directly to the OS unchanged — F-row default actions keep working.
pub fn setMatches(self: *Self, matches: []const Match) !void {
    if (self.running) return error.AlreadyRunning;

    if (self.owned_matches.len > 0) self.allocator.free(self.owned_matches);
    self.owned_matches = try self.allocator.dupe(Match, matches);
    errdefer {
        self.allocator.free(self.owned_matches);
        self.owned_matches = &.{};
    }

    const dicts = try buildMatchDicts(matches);
    defer c.CFRelease(dicts);
    c.IOHIDManagerSetDeviceMatchingMultiple(self.manager, dicts);
}

/// Build the CFArray of matching dictionaries for `matches`. Shared by
/// the seize manager (`setMatches`) and the liveness probe's throwaway
/// manager (`pollLiveness`) so both enumerate by identical criteria —
/// the probe can't drift from what we actually seize. Caller releases.
fn buildMatchDicts(matches: []const Match) !c.CFArrayRef {
    // Capacity 0 = unbounded: a built-in alias expands to one dict per
    // transport, so the dict count can exceed matches.len.
    const dicts = c.CFArrayCreateMutable(c.kCFAllocatorDefault, 0, &c.kCFTypeArrayCallBacks);
    if (dicts == null) return error.CFArrayCreateFailed;
    errdefer c.CFRelease(dicts);

    for (matches) |m| {
        // Partial-zero (one of vendor/product is 0, the other isn't) is
        // neither a FIFO built-in (both zero) nor a real external device
        // (both non-zero) — it matches nothing. Warn so misconfigured
        // aliases don't fail silently.
        if ((m.vendor == 0) != (m.product == 0)) {
            log.warn("device alias with partial-zero VID/PID (vendor=0x{x}, product=0x{x}) will match nothing — use both zero for FIFO built-in keyboards, or both non-zero for an external device", .{ m.vendor, m.product });
        }

        const pred = matchPredicate(m);
        if (pred.transports.len > 0) {
            for (pred.transports) |t| {
                try appendMatchDict(dicts, null, null, t);
            }
        } else {
            try appendMatchDict(dicts, pred.vendor, pred.product, null);
        }
    }

    return dicts;
}

/// Schedule the manager on the current run loop and open it.
///
/// `mode = .seize` opens with `kIOHIDOptionsTypeSeizeDevice` so the
/// matched keyboards' events bypass the kernel HID stack and only
/// flow into our `callback`.
///
/// `mode = .observe` opens passively — the kernel still sees the
/// device's events and routes them to the foreground app; we get a
/// copy via the callback. Used for diagnostics: confirms our matching
/// + run-loop wiring before troubleshooting seize-specific issues.
pub const Mode = enum { seize, observe };

pub fn start(self: *Self, mode: Mode) !void {
    if (self.running) return;

    c.IOHIDManagerRegisterInputValueCallback(self.manager, valueCallback, self);
    // Per-device add/remove notifications. Logging-only — re-seize on
    // wake is driven by PowerNotify so we don't double-trigger here.
    // These fire after manager open: matching for the initial
    // population and again for any device that re-enumerates (e.g.
    // unplug/replug, or post-sleep stale-ref replacement).
    c.IOHIDManagerRegisterDeviceMatchingCallback(self.manager, deviceMatchedCallback, self);
    c.IOHIDManagerRegisterDeviceRemovalCallback(self.manager, deviceRemovedCallback, self);
    c.IOHIDManagerScheduleWithRunLoop(self.manager, c.CFRunLoopGetCurrent(), c.kCFRunLoopDefaultMode);

    self.open_options = switch (mode) {
        .seize => c.kIOHIDOptionsTypeSeizeDevice,
        .observe => c.kIOHIDOptionsTypeNone,
    };
    const r = c.IOHIDManagerOpen(self.manager, self.open_options);
    if (r != c.kIOReturnSuccess) {
        c.IOHIDManagerUnscheduleFromRunLoop(self.manager, c.CFRunLoopGetCurrent(), c.kCFRunLoopDefaultMode);
        log.err("IOHIDManagerOpen seize failed: 0x{X:0>8}", .{@as(u32, @bitCast(r))});
        return switch (r) {
            c.kIOReturnNotPrivileged => error.NotPrivileged,
            // kIOReturnNotPermitted: macOS TCC layer denied the
            // operation — usually means the binary needs to be
            // approved in System Settings → Privacy & Security →
            // Input Monitoring. The first attempt triggers the
            // approval dialog; subsequent runs are silent.
            c.kIOReturnNotPermitted => error.NotPermitted,
            c.kIOReturnExclusiveAccess => error.DeviceAlreadySeized,
            else => error.IOHIDManagerOpenFailed,
        };
    }

    self.running = true;

    const matched = c.IOHIDManagerCopyDevices(self.manager);
    const count: usize = if (matched) |s| @intCast(c.CFSetGetCount(s)) else 0;
    log.info("seized matching devices (options=0x{x}, matched_count={d})", .{ self.open_options, count });
    if (count == 0) {
        log.warn("matching dictionary captured 0 devices — vendor/product mismatch?", .{});
    }

    // No post-match filtering needed: the matching dicts are exact. The
    // (0,0) built-in matches only Transport ∈ {FIFO,SPI} keyboards (the
    // internal one); external keyboards report USB/Bluetooth, and the
    // Karabiner VHIDD we inject into exposes no Transport property at all
    // (verified), so none of them can match. Explicit (vendor,product)
    // aliases match only their own device. So every seized device is one
    // we were asked to seize.
    if (matched) |s| c.CFRelease(s);

    if (mode == .seize) {
        self.disableCapsLockDelayOnMatches(self.owned_matches);
        self.captureSeizedEntryIds();
    }
}

/// Snapshot the IORegistry entry IDs of the devices the seize manager
/// currently holds. Called at the end of `start(.seize)` and after every
/// re-seize so the liveness watchdog compares against the ID set that is
/// actually live. Best-effort: on any allocation/IOKit hiccup we leave
/// the set empty, which the watchdog treats as "can't tell" rather than
/// forcing a spurious re-seize.
fn captureSeizedEntryIds(self: *Self) void {
    if (self.seized_entry_ids.len > 0) {
        self.allocator.free(self.seized_entry_ids);
        self.seized_entry_ids = &.{};
    }
    self.seized_entry_ids = self.collectEntryIds(self.manager) catch &.{};
}

/// Read the registry entry IDs of every device a manager currently
/// matches. Allocates the returned slice (caller owns). Devices whose
/// service can't be resolved (entry ID 0) are skipped — they can't be
/// compared meaningfully, and including 0 would make two unrelated
/// unknowns look equal.
fn collectEntryIds(self: *Self, manager: c.IOHIDManagerRef) ![]u64 {
    const set = c.IOHIDManagerCopyDevices(manager) orelse return &.{};
    defer c.CFRelease(set);
    const count: usize = @intCast(c.CFSetGetCount(set));
    if (count == 0) return &.{};

    const refs = try self.allocator.alloc(?*const anyopaque, count);
    defer self.allocator.free(refs);
    c.CFSetGetValues(set, refs.ptr);

    var ids = try std.ArrayList(u64).initCapacity(self.allocator, count);
    errdefer ids.deinit(self.allocator);
    for (refs) |ref| {
        const dev: c.IOHIDDeviceRef = @constCast(ref);
        const id = deviceEntryId(dev);
        if (id != 0) ids.appendAssumeCapacity(id);
    }
    return ids.toOwnedSlice(self.allocator);
}

/// Map an IOHIDDevice to its IORegistry entry ID. Returns 0 if the
/// device has no backing service (a stale ref can report this) or the
/// registry read fails.
fn deviceEntryId(device: c.IOHIDDeviceRef) u64 {
    const service = c.IOHIDDeviceGetService(device);
    if (service == 0) return 0;
    var id: u64 = 0;
    if (c.IORegistryEntryGetRegistryEntryID(service, &id) != c.kIOReturnSuccess) return 0;
    return id;
}

/// Result of a liveness check. `.indeterminate` means the probe itself
/// couldn't enumerate (transient IOKit failure) — the caller leaves the
/// seize alone rather than rebuilding on no evidence.
pub const Liveness = enum { ok, stale, indeterminate };

/// Detect whether the devices we seized are still the live ones. For
/// each entry ID captured at seize time, ask IOKit whether that exact
/// registry entry still exists (`registryEntryAlive`). This queries the
/// IORegistry directly — it never opens a device, so unlike a second
/// IOHIDManager it can't collide with our own exclusive seize (which
/// makes a rival open return kIOReturnExclusiveAccess). When a built-in
/// keyboard re-enumerates across sleep/DarkWake it gets a *fresh*
/// registry entry, so the ID we hold stops resolving — that vanished ID
/// is ground-truth proof the seize is stale, independent of whether
/// IOHIDManager ever fired a matching/removal callback.
///
/// Scope note: this catches the documented failure (a seized device
/// re-enumerating under us). It does not, by itself, catch "a brand-new
/// keyboard appeared that we should seize but never did" — device
/// arrival is still covered by the IOHIDManager matching callback,
/// PowerNotify, and the next apply_rules.
pub fn pollLiveness(self: *Self) Liveness {
    if (!self.running) return .indeterminate;
    if (self.seized_entry_ids.len == 0) return .indeterminate; // nothing captured to check

    const alive = self.liveSeizedIds() catch return .indeterminate;
    defer if (alive.len > 0) self.allocator.free(alive);

    // info: fires every watchdog tick, so it is compiled out of the
    // ReleaseFast release (keeps only warn+) and only shows in a
    // ReleaseSafe/Debug build when tracing a "keyboard went dead"
    // recurrence. This is the forensic record of which seized devices
    // were still in the registry at each tick.
    log.info("liveness: seized_ids={any} still_alive={any}", .{ self.seized_entry_ids, alive });

    return if (entryIdSetsMatch(self.seized_entry_ids, alive)) .ok else .stale;
}

/// Return the subset of `seized_entry_ids` whose registry entries still
/// exist. A shorter result than the seized set means a seized device
/// vanished (re-enumerated/terminated) → the caller treats it as stale.
fn liveSeizedIds(self: *Self) ![]u64 {
    var alive = try std.ArrayList(u64).initCapacity(self.allocator, self.seized_entry_ids.len);
    errdefer alive.deinit(self.allocator);
    for (self.seized_entry_ids) |id| {
        if (registryEntryAlive(id)) alive.appendAssumeCapacity(id);
    }
    return alive.toOwnedSlice(self.allocator);
}

/// True if a registry entry with this ID currently exists. Resolves the
/// ID to a service without opening it; releases the service immediately.
fn registryEntryAlive(entry_id: u64) bool {
    // IORegistryEntryIDMatching returns a +1 dict that
    // IOServiceGetMatchingService consumes — we must not release it.
    const matching = c.IORegistryEntryIDMatching(entry_id);
    if (matching == null) return false;
    const service = c.IOServiceGetMatchingService(c.kIOMainPortDefault, matching);
    if (service == 0) return false;
    _ = c.IOObjectRelease(service);
    return true;
}

/// Set equality on registry entry IDs (order-independent, IDs are
/// unique so no multiset concerns). Pure so the watchdog's decision is
/// unit-testable without a live IOHIDManager.
fn entryIdSetsMatch(seized: []const u64, live: []const u64) bool {
    if (seized.len != live.len) return false;
    for (live) |id| {
        if (std.mem.indexOfScalar(u64, seized, id) == null) return false;
    }
    return true;
}

test entryIdSetsMatch {
    const expectEqual = std.testing.expectEqual;
    // identical sets (any order) → match
    try expectEqual(true, entryIdSetsMatch(&.{ 1, 2, 3 }, &.{ 3, 1, 2 }));
    // both empty (login window / no keyboard) → match, no spurious reseize
    try expectEqual(true, entryIdSetsMatch(&.{}, &.{}));
    // device re-enumerated: same count, one fresh ID → stale
    try expectEqual(false, entryIdSetsMatch(&.{ 1, 2 }, &.{ 1, 9 }));
    // a keyboard appeared that we never seized → stale
    try expectEqual(false, entryIdSetsMatch(&.{1}, &.{ 1, 2 }));
    // seized device vanished from the live set → stale
    try expectEqual(false, entryIdSetsMatch(&.{ 1, 2 }, &.{1}));
    // seized nothing but a keyboard is now present → stale (reseize it)
    try expectEqual(false, entryIdSetsMatch(&.{}, &.{1}));
}

/// Set HIDKeyboardCapsLockDelayOverride=0 on every event-system
/// service. Disables Apple's firmware-level "hold caps_lock for ~150ms
/// to toggle" behavior — without this the toggle still fires through
/// a side channel that IOHIDManager seize doesn't capture, so
/// caps_lock-as-ctrl works at the FSM level but the OS's caps_lock
/// state diverges (LED on, caps stuck).
///
/// Going through `IOHIDEventSystemClient` (private API) is what
/// Karabiner does — `IOHIDDeviceSetProperty` returns success but the
/// property is silently rejected, and `hidutil property --set`
/// likewise doesn't persist. The event-system path takes effect.
///
/// We don't try to filter by vendor/product (event-system services
/// don't expose those keys reliably) — setting the property on
/// services that don't accept it is a no-op, and any keyboard where
/// it does apply benefits from the same behavior we'd want.
fn disableCapsLockDelayOnMatches(self: *Self, matches: []const Match) void {
    _ = self;
    _ = matches;
    const evs = c.IOHIDEventSystemClientCreateSimpleClient(c.kCFAllocatorDefault);
    if (evs == null) {
        log.warn("IOHIDEventSystemClientCreateSimpleClient failed — caps_lock firmware toggle stays enabled", .{});
        return;
    }
    defer c.CFRelease(evs);

    const services = c.IOHIDEventSystemClientCopyServices(evs);
    if (services == null) {
        log.warn("IOHIDEventSystemClientCopyServices returned null", .{});
        return;
    }
    defer c.CFRelease(services);

    const delay_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, c.kIOHIDKeyboardCapsLockDelayOverrideKey, c.kCFStringEncodingUTF8);
    if (delay_key == null) return;
    defer c.CFRelease(delay_key);

    var zero: i32 = 0;
    const zero_cf = c.CFNumberCreate(c.kCFAllocatorDefault, c.kCFNumberSInt32Type, &zero);
    if (zero_cf == null) return;
    defer c.CFRelease(zero_cf);

    var applied: usize = 0;
    const total = c.CFArrayGetCount(services);
    var i: c.CFIndex = 0;
    while (i < total) : (i += 1) {
        const raw = c.CFArrayGetValueAtIndex(services, i) orelse continue;
        const svc: c.IOHIDServiceClientRef = @constCast(raw);
        const ok = c.IOHIDServiceClientSetProperty(svc, delay_key, zero_cf);
        if (ok != 0) applied += 1;
    }
    log.info("HIDKeyboardCapsLockDelayOverride=0 applied to {d}/{d} service(s)", .{ applied, total });
}

pub fn stop(self: *Self) void {
    if (!self.running) return;
    _ = c.IOHIDManagerClose(self.manager, self.open_options);
    c.IOHIDManagerUnscheduleFromRunLoop(self.manager, c.CFRunLoopGetCurrent(), c.kCFRunLoopDefaultMode);
    self.running = false;
    log.info("released seize", .{});
}

fn deviceIdsLog(prefix: []const u8, device: c.IOHIDDeviceRef) void {
    const vendor = deviceI32Property(device, c.kIOHIDVendorIDKey);
    const product = deviceI32Property(device, c.kIOHIDProductIDKey);
    // info: fires on every apply_rules and device add/remove, so it's
    // compiled out of the release build (ReleaseFast keeps only warn+)
    // and won't accumulate on users' machines. Visible in a ReleaseSafe
    // build for "did our seized device disappear?" tracing.
    log.info("{s}: vendor=0x{X:0>4} product=0x{X:0>4}", .{ prefix, vendor, product });
}

fn deviceI32Property(device: c.IOHIDDeviceRef, key_cstr: [*:0]const u8) u32 {
    const key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, key_cstr, c.kCFStringEncodingUTF8);
    if (key == null) return 0;
    defer c.CFRelease(key);
    const value = c.IOHIDDeviceGetProperty(device, key);
    if (value == null) return 0;
    var out: i32 = 0;
    _ = c.CFNumberGetValue(value, c.kCFNumberSInt32Type, &out);
    return @bitCast(out);
}

fn deviceMatchedCallback(
    ctx: ?*anyopaque,
    result: c.IOReturn,
    sender: ?*anyopaque,
    device: c.IOHIDDeviceRef,
) callconv(.c) void {
    _ = ctx;
    _ = sender;
    if (result != c.kIOReturnSuccess) return;
    deviceIdsLog("device matched", device);
}

fn deviceRemovedCallback(
    ctx: ?*anyopaque,
    result: c.IOReturn,
    sender: ?*anyopaque,
    device: c.IOHIDDeviceRef,
) callconv(.c) void {
    _ = ctx;
    _ = sender;
    if (result != c.kIOReturnSuccess) return;
    deviceIdsLog("device removed", device);
}

fn valueCallback(
    ctx: ?*anyopaque,
    result: c.IOReturn,
    sender: ?*anyopaque,
    value: c.IOHIDValueRef,
) callconv(.c) void {
    _ = sender;
    if (result != c.kIOReturnSuccess) return;
    const self: *Self = @ptrCast(@alignCast(ctx orelse return));

    const element = c.IOHIDValueGetElement(value);
    if (element == null) return;

    const usage_page = c.IOHIDElementGetUsagePage(element);
    const usage = c.IOHIDElementGetUsage(element);
    const int_value = c.IOHIDValueGetIntegerValue(value);

    self.callback(self.callback_ctx, .{
        .usage_page = usage_page,
        .usage = usage,
        .pressed = int_value != 0,
    });
}

const testing = std.testing;

test "matchPredicate: FIFO built-in (0,0) scopes to internal transports, omits VID/PID" {
    // The bug this guards: a (0,0) alias must NOT match every keyboard by
    // usage alone (which seized external keyboards + the VHIDD). It scopes
    // to the internal-bus transports so IOKit only offers the built-in.
    const p = matchPredicate(.{ .vendor = 0, .product = 0 });
    try testing.expectEqual(@as(?u32, null), p.vendor);
    try testing.expectEqual(@as(?u32, null), p.product);
    try testing.expectEqualSlices([:0]const u8, &builtin_transports, p.transports);
}

test "matchPredicate: external device matches VID/PID, no transport constraint" {
    // NEO ERGO WIRED — the keyboard that was wrongly seized. An explicit
    // (vendor,product) alias targets that exact device and sets no
    // transport (it is, by definition, external).
    const p = matchPredicate(.{ .vendor = 0x4e45, .product = 0x4552 });
    try testing.expectEqual(@as(?u32, 0x4e45), p.vendor);
    try testing.expectEqual(@as(?u32, 0x4552), p.product);
    try testing.expectEqual(@as(usize, 0), p.transports.len);
}

// Live check that the production (0,0) match excludes externals on real
// hardware — the thing a unit test can't assert. Gated behind
// SKHD_HID_LIVE=1 (CI has no keyboard); run with an external attached:
//
//     SKHD_HID_LIVE=1 zig build test
//
// Opens in observe mode (no seize, so no root) and inspects the match
// alone: a non-zero VendorID in the matched set means the transport
// scope failed here. (Built-In can't be used — IOHIDManager matching
// ignores it; only Transport is honored.)
test "live: (0,0) match excludes external keyboards" {
    if (std.c.getenv("SKHD_HID_LIVE") == null) return error.SkipZigTest;

    const noop = struct {
        fn cb(_: ?*anyopaque, _: Event) void {}
    };
    const self = try init(testing.allocator, noop.cb, null);
    defer self.deinit();

    try self.setMatches(&.{.{ .vendor = 0, .product = 0 }});

    self.open_options = c.kIOHIDOptionsTypeNone;
    const r = c.IOHIDManagerOpen(self.manager, self.open_options);
    if (r != c.kIOReturnSuccess) {
        std.debug.print("IOHIDManagerOpen(observe) failed: 0x{X:0>8} — cannot verify\n", .{@as(u32, @bitCast(r))});
        return error.CannotVerify;
    }
    defer _ = c.IOHIDManagerClose(self.manager, self.open_options);

    const matched = c.IOHIDManagerCopyDevices(self.manager) orelse {
        std.debug.print("no devices matched — cannot verify (keyboard connected?)\n", .{});
        return error.CannotVerify;
    };
    defer c.CFRelease(matched);

    const n: usize = @intCast(c.CFSetGetCount(matched));
    try testing.expect(n > 0); // The match must still find the internal keyboard.

    const buf = try testing.allocator.alloc(?*const anyopaque, n);
    defer testing.allocator.free(buf);
    c.CFSetGetValues(matched, buf.ptr);

    const vid_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, c.kIOHIDVendorIDKey, c.kCFStringEncodingUTF8);
    defer if (vid_key) |k| c.CFRelease(k);

    var builtin_count: usize = 0;
    var external_count: usize = 0;
    for (buf) |raw| {
        const dev: c.IOHIDDeviceRef = @constCast(raw);
        var vid: i32 = 0;
        if (vid_key) |k| {
            const prop = c.IOHIDDeviceGetProperty(dev, k);
            if (prop != null) {
                _ = c.CFNumberGetValue(@ptrCast(prop), c.kCFNumberSInt32Type, @ptrCast(&vid));
            }
        }
        if (vid == 0) {
            builtin_count += 1;
        } else {
            external_count += 1;
            std.debug.print("UNEXPECTED: (0,0) match captured a non-built-in device VendorID=0x{x}\n", .{@as(u32, @bitCast(vid))});
        }
    }
    std.debug.print("(0,0) match -> {d} built-in (VID-less), {d} external\n", .{ builtin_count, external_count });

    // The fix: a VID-less built-in matched, and nothing with a real
    // VendorID did. external_count > 0 means the transport scope didn't
    // hold on this machine and the seize would leak onto externals.
    try testing.expectEqual(@as(usize, 0), external_count);
    try testing.expect(builtin_count > 0);
}
