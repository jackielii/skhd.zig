//! HID-level key remap management via the `hidutil` command-line tool.
//!
//! Used by the `.remap` feature: collect all `RemapDecl` entries from
//! `Mappings`, group by device alias, and apply them as per-device
//! `UserKeyMapping` properties through `hidutil property --matching ...
//! --set ...`. On exit (signal handler or `deinit`) the same per-device
//! property is cleared so the user's keyboard returns to default.
//!
//! Crash recovery: before each apply, write a state file at
//! `~/.cache/skhd/hidutil_state.json` listing the touched
//! (vendor, product) pairs and our pid. At startup, if the file exists
//! with a dead pid, clear the listed devices first so a previous crashed
//! instance doesn't leave the user with a broken caps_lock.
//!
//! V1 caveat: we don't preserve any pre-existing `UserKeyMapping`. If
//! another tool (Hyperkey, manual hidutil invocations) has set one, we
//! overwrite it on apply and clear to empty on restore. Document this
//! limitation in user-facing docs.

const std = @import("std");
const Mappings = @import("Mappings.zig");
const HidKeyMap = @import("HidKeyMap.zig");
const log = std.log.scoped(.hidutil);

const Hidutil = @This();

allocator: std.mem.Allocator,
io: std.Io,
/// Devices we currently have a UserKeyMapping applied on. Populated by
/// applyRemaps; consulted by restoreAll. Owned strings.
applied_devices: std.ArrayListUnmanaged(VendorProduct),
state_path: []const u8,

pub const VendorProduct = struct {
    vendor: u32,
    product: u32,
};

pub fn init(allocator: std.mem.Allocator, io: std.Io) !*Hidutil {
    const state_path = try resolveStatePath(allocator);
    errdefer allocator.free(state_path);

    const self = try allocator.create(Hidutil);
    self.* = .{
        .allocator = allocator,
        .io = io,
        .applied_devices = .empty,
        .state_path = state_path,
    };
    return self;
}

pub fn deinit(self: *Hidutil) void {
    self.applied_devices.deinit(self.allocator);
    self.allocator.free(self.state_path);
    self.allocator.destroy(self);
}

/// Apply every `.remap` declaration in the given Mappings. Groups by
/// device alias, resolves alias → (vendor, product), and shell-outs to
/// `hidutil property --matching '...' --set '...'` once per device.
/// Records the set of touched devices to the state file before any
/// invocation so a crash mid-apply still leaves recoverable state.
pub fn applyRemaps(self: *Hidutil, mappings: *const Mappings) !void {
    if (mappings.remaps.items.len == 0) return;

    // Group remaps by device alias. Most users have 1–2 devices, so a
    // small ArrayList of (alias, ArrayList(RemapDecl)) is fine.
    var groups = std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(Mappings.RemapDecl)){};
    defer {
        var it = groups.iterator();
        while (it.next()) |kv| kv.value_ptr.deinit(self.allocator);
        groups.deinit(self.allocator);
    }
    for (mappings.remaps.items) |r| {
        const gop = try groups.getOrPut(self.allocator, r.device_alias);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, r);
    }

    // Snapshot which (vendor, product) we'll touch — write state before
    // executing so a crash mid-loop is recoverable.
    self.applied_devices.clearRetainingCapacity();
    var it = groups.iterator();
    while (it.next()) |kv| {
        const alias = mappings.device_aliases.get(kv.key_ptr.*) orelse {
            log.err("Internal error: alias '{s}' missing from device_aliases at apply time", .{kv.key_ptr.*});
            return error.UnknownDeviceAlias;
        };
        try self.applied_devices.append(self.allocator, .{ .vendor = alias.vendor, .product = alias.product });
    }
    try self.writeState();

    // Apply each device's mapping. Failure on one device doesn't abort
    // the rest (we already recorded the device in state, so cleanup will
    // clear them on exit).
    var any_failure = false;
    var grp_it = groups.iterator();
    while (grp_it.next()) |kv| {
        const alias = mappings.device_aliases.get(kv.key_ptr.*).?;
        applyForDevice(self.allocator, self.io, alias.vendor, alias.product, kv.value_ptr.items) catch |err| {
            log.err("Failed to apply remap for device '{s}' ({x:0>4}:{x:0>4}): {s}", .{ kv.key_ptr.*, alias.vendor, alias.product, @errorName(err) });
            any_failure = true;
        };
    }
    if (any_failure) return error.PartialApply;
}

/// Restore all applied remaps by clearing UserKeyMapping on each touched
/// device. Idempotent. Called on clean exit, signal handlers, and crash
/// recovery (where `applied_devices` was populated from the state file).
pub fn restoreAll(self: *Hidutil) void {
    for (self.applied_devices.items) |vp| {
        clearForDevice(self.allocator, self.io, vp.vendor, vp.product) catch |err| {
            log.err("Failed to clear UserKeyMapping on {x:0>4}:{x:0>4}: {s}", .{ vp.vendor, vp.product, @errorName(err) });
        };
    }
    self.applied_devices.clearRetainingCapacity();
    self.deleteState() catch {};
}

/// Startup recovery. If the state file exists and the pid recorded in it
/// is no longer running, populate `applied_devices` from the file and
/// clear those devices via `restoreAll`. This unsticks a user whose
/// previous skhd instance was killed via SIGKILL or panicked before it
/// could restore.
pub fn recoverFromCrash(self: *Hidutil) !void {
    const content = std.Io.Dir.cwd().readFileAlloc(self.io, self.state_path, self.allocator, .limited(64 * 1024)) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer self.allocator.free(content);

    const parsed = std.json.parseFromSlice(StateFile, self.allocator, content, .{}) catch |err| {
        log.warn("hidutil state file at '{s}' is malformed ({s}); ignoring.", .{ self.state_path, @errorName(err) });
        return;
    };
    defer parsed.deinit();

    if (isProcessRunning(parsed.value.pid)) {
        log.warn("hidutil state file's pid {d} is still running — assuming the other instance owns the remaps. Skipping crash recovery.", .{parsed.value.pid});
        return;
    }

    log.warn("Recovering from crashed pid {d}: clearing UserKeyMapping on {d} device(s)", .{ parsed.value.pid, parsed.value.devices.len });
    for (parsed.value.devices) |d| {
        try self.applied_devices.append(self.allocator, .{ .vendor = d.vendor, .product = d.product });
    }
    self.restoreAll();
}

const StateFile = struct {
    pid: i32,
    devices: []VendorProduct,
};

fn writeState(self: *Hidutil) !void {
    // Ensure parent dir exists. Errors here are fatal — without the
    // state file we can't recover from a future crash.
    if (std.fs.path.dirname(self.state_path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(self.io, dir);
    }

    const state = StateFile{
        .pid = @intCast(std.c.getpid()),
        .devices = self.applied_devices.items,
    };
    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    try std.json.Stringify.value(state, .{}, &aw.writer);
    try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.state_path, .data = aw.written() });
}

fn deleteState(self: *Hidutil) !void {
    std.Io.Dir.cwd().deleteFile(self.io, self.state_path) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
}

fn resolveStatePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = @import("utils.zig").getenv("HOME") orelse return error.HomeNotSet;
    return try std.fmt.allocPrint(allocator, "{s}/.cache/skhd/hidutil_state.json", .{home});
}

fn isProcessRunning(pid: i32) bool {
    // kill(pid, 0) returns 0 if process exists and we have permission.
    // -1 with ESRCH means no such process.
    return std.c.kill(pid, @enumFromInt(0)) == 0;
}

fn applyForDevice(allocator: std.mem.Allocator, io: std.Io, vendor: u32, product: u32, remaps: []const Mappings.RemapDecl) !void {
    var json_buf: std.Io.Writer.Allocating = .init(allocator);
    defer json_buf.deinit();
    const w = &json_buf.writer;
    try w.writeAll("{\"UserKeyMapping\":[");
    for (remaps, 0..) |r, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"HIDKeyboardModifierMappingSrc\":{d},\"HIDKeyboardModifierMappingDst\":{d}}}", .{ HidKeyMap.fullUsage(r.src_usage), HidKeyMap.fullUsage(r.dst_usage) });
    }
    try w.writeAll("]}");

    var matching_buf: [128]u8 = undefined;
    const matching = try buildMatching(&matching_buf, vendor, product);

    try runHidutilSet(allocator, io, matching, json_buf.written());
}

fn clearForDevice(allocator: std.mem.Allocator, io: std.Io, vendor: u32, product: u32) !void {
    var matching_buf: [128]u8 = undefined;
    const matching = try buildMatching(&matching_buf, vendor, product);
    try runHidutilSet(allocator, io, matching, "{\"UserKeyMapping\":[]}");
}

/// FIFO-transport built-in keyboards have no VendorID/ProductID in IOKit;
/// hidutil treats `{"VendorID":0,"ProductID":0}` as a wildcard and applies
/// the mapping to every connected keyboard. For the 0/0 case, match by
/// `Built-In: 1` + keyboard usage so only the internal keyboard is touched.
fn buildMatching(buf: []u8, vendor: u32, product: u32) ![]u8 {
    if (vendor == 0 and product == 0) {
        return std.fmt.bufPrint(buf, "{{\"Built-In\":1,\"PrimaryUsagePage\":1,\"PrimaryUsage\":6}}", .{});
    }
    // Partial-zero (one is 0, the other isn't) hits hidutil's wildcard
    // semantics on the zero side — the mapping leaks to every keyboard
    // that happens to match the non-zero side. Warn loudly.
    if ((vendor == 0) != (product == 0)) {
        log.warn("device alias with partial-zero VID/PID (vendor=0x{x}, product=0x{x}) will match unintended keyboards — use both zero for FIFO built-in, or both non-zero for an external device", .{ vendor, product });
    }
    return std.fmt.bufPrint(buf, "{{\"VendorID\":{d},\"ProductID\":{d}}}", .{ vendor, product });
}

fn runHidutilSet(allocator: std.mem.Allocator, io: std.Io, matching: []const u8, set_value: []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{
            "/usr/bin/hidutil",
            "property",
            "--matching",
            matching,
            "--set",
            set_value,
        },
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        log.err("hidutil failed (term={any}): {s}", .{ result.term, std.mem.trim(u8, result.stderr, " \r\n\t") });
        return error.HidutilFailed;
    }
}

test "buildMatching: non-zero VID/PID uses VendorID/ProductID predicate" {
    var buf: [128]u8 = undefined;
    const out = try buildMatching(&buf, 0x05AC, 0x0342);
    try std.testing.expectEqualStrings("{\"VendorID\":1452,\"ProductID\":834}", out);
}

test "buildMatching: zero VID/PID uses Built-In predicate" {
    var buf: [128]u8 = undefined;
    const out = try buildMatching(&buf, 0, 0);
    try std.testing.expectEqualStrings("{\"Built-In\":1,\"PrimaryUsagePage\":1,\"PrimaryUsage\":6}", out);
}

test "buildMatching: partial-zero still emits literal 0 (warning logged elsewhere)" {
    var buf: [128]u8 = undefined;
    const out_v = try buildMatching(&buf, 0, 0x1234);
    try std.testing.expectEqualStrings("{\"VendorID\":0,\"ProductID\":4660}", out_v);
    const out_p = try buildMatching(&buf, 0x1234, 0);
    try std.testing.expectEqualStrings("{\"VendorID\":4660,\"ProductID\":0}", out_p);
}

test "VendorProduct round-trip via state file" {
    const alloc = std.testing.allocator;
    var devices = [_]VendorProduct{
        .{ .vendor = 0x05AC, .product = 0x0342 },
        .{ .vendor = 0x04FE, .product = 0x0021 },
    };
    const state = StateFile{
        .pid = 12345,
        .devices = devices[0..],
    };
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try std.json.Stringify.value(state, .{}, &aw.writer);

    const parsed = try std.json.parseFromSlice(StateFile, alloc, aw.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i32, 12345), parsed.value.pid);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.devices.len);
    try std.testing.expectEqual(@as(u32, 0x05AC), parsed.value.devices[0].vendor);
}
