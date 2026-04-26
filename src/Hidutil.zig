//! HID-level key remap management via the `hidutil` command-line tool.
//!
//! Used by the `.remap` feature: collect all `RemapDecl` entries from
//! `Mappings`, group by device alias, and apply them as per-device
//! `UserKeyMapping` properties.
//!
//! Coexistence with System Settings → Modifier Keys: that panel writes
//! to the same per-device UserKeyMapping array we use. To avoid wiping
//! the user's prior settings, we GET the existing array per device on
//! apply, save it, merge in our entries (replacing any with the same
//! source key), and SET the union. On exit we re-SET the saved
//! original so the user's prior config is preserved.
//!
//! Crash recovery: before each apply, write a state file at
//! `~/.cache/skhd/hidutil_state.json` containing the originals plus
//! our pid. At startup, if the file exists with a dead pid, restore
//! the originals so a previous crashed instance doesn't leave the
//! user's keyboard in our remapped state.

const std = @import("std");
const Mappings = @import("Mappings.zig");
const HidKeyMap = @import("HidKeyMap.zig");
const log = std.log.scoped(.hidutil);

const Hidutil = @This();

allocator: std.mem.Allocator,
/// Devices we currently have a UserKeyMapping applied on, with the
/// original mapping captured before we modified it. Populated by
/// applyRemaps; consulted by restoreAll.
applied_devices: std.ArrayListUnmanaged(AppliedDevice),
state_path: []const u8,

pub const VendorProduct = struct {
    vendor: u32,
    product: u32,
};

/// One entry per device we've touched. `original` is the pre-existing
/// UserKeyMapping read from the device on apply — restored verbatim on
/// shutdown so System Settings → Modifier Keys (and Hyperkey, etc.)
/// survive a skhd run.
pub const AppliedDevice = struct {
    vendor: u32,
    product: u32,
    /// Caller-owned slice of {src, dst} pairs the device had before we
    /// applied our remap. Restored on deinit / signal handler.
    original: []ModifierMapping,
};

pub const ModifierMapping = struct {
    /// Full HID usage value (page << 32 | usage). Matches the format
    /// hidutil's UserKeyMapping JSON expects.
    src: u64,
    dst: u64,
};

pub fn init(allocator: std.mem.Allocator) !*Hidutil {
    const state_path = try resolveStatePath(allocator);
    errdefer allocator.free(state_path);

    const self = try allocator.create(Hidutil);
    self.* = .{
        .allocator = allocator,
        .applied_devices = .empty,
        .state_path = state_path,
    };
    return self;
}

pub fn deinit(self: *Hidutil) void {
    for (self.applied_devices.items) |ad| self.allocator.free(ad.original);
    self.applied_devices.deinit(self.allocator);
    self.allocator.free(self.state_path);
    self.allocator.destroy(self);
}

/// Apply every `.remap` declaration in the given Mappings. Groups by
/// device alias, resolves alias → (vendor, product), reads the
/// pre-existing UserKeyMapping per device, merges in our entries (our
/// entries replace any with the same source key), and SETs the union.
/// Records the originals to the state file before any modification so
/// a crash mid-apply still leaves recoverable state.
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

    // For each device: read existing UserKeyMapping (so we can restore
    // it later and merge with it now), record into applied_devices,
    // write state file, then issue --set with the merged array.
    self.applied_devices.clearRetainingCapacity();
    var it = groups.iterator();
    while (it.next()) |kv| {
        const alias = mappings.device_aliases.get(kv.key_ptr.*) orelse {
            log.err("Internal error: alias '{s}' missing from device_aliases at apply time", .{kv.key_ptr.*});
            return error.UnknownDeviceAlias;
        };
        const existing = readExistingMapping(self.allocator, alias.vendor, alias.product) catch |err| blk: {
            log.warn("Could not read existing UserKeyMapping for {x:0>4}:{x:0>4}: {s}. Treating as empty (your prior setting may not be restored).", .{ alias.vendor, alias.product, @errorName(err) });
            break :blk try self.allocator.alloc(ModifierMapping, 0);
        };
        try self.applied_devices.append(self.allocator, .{
            .vendor = alias.vendor,
            .product = alias.product,
            .original = existing,
        });
    }
    try self.writeState();

    // Apply each device's merged mapping. Failure on one device doesn't
    // abort the rest (we already recorded the device + original in state,
    // so cleanup will restore them on exit).
    var any_failure = false;
    for (self.applied_devices.items, 0..) |ad, idx| {
        // Find the corresponding RemapDecls. groups iteration order
        // matches applied_devices push order so idx lines up.
        const decls = blk: {
            var grp_it = groups.iterator();
            var i: usize = 0;
            while (grp_it.next()) |kv| : (i += 1) {
                if (i == idx) break :blk kv.value_ptr.items;
            }
            break :blk &[_]Mappings.RemapDecl{};
        };
        applyForDevice(self.allocator, ad.vendor, ad.product, decls, ad.original) catch |err| {
            log.err("Failed to apply remap for {x:0>4}:{x:0>4}: {s}", .{ ad.vendor, ad.product, @errorName(err) });
            any_failure = true;
        };
    }
    if (any_failure) return error.PartialApply;
}

/// Restore all applied remaps by writing the saved original
/// UserKeyMapping back to each touched device. Idempotent. Called on
/// clean exit, signal handlers, and crash recovery (where
/// applied_devices was populated from the state file).
pub fn restoreAll(self: *Hidutil) void {
    for (self.applied_devices.items) |ad| {
        setForDevice(self.allocator, ad.vendor, ad.product, ad.original) catch |err| {
            log.err("Failed to restore UserKeyMapping on {x:0>4}:{x:0>4}: {s}", .{ ad.vendor, ad.product, @errorName(err) });
        };
        self.allocator.free(ad.original);
    }
    self.applied_devices.clearRetainingCapacity();
    self.deleteState() catch {};
}

/// Startup recovery. If the state file exists and the pid recorded in it
/// is no longer running, populate applied_devices from the file and
/// restore the saved originals. This unsticks a user whose previous
/// skhd instance was killed via SIGKILL or panicked before it could
/// restore.
pub fn recoverFromCrash(self: *Hidutil) !void {
    const file = std.fs.cwd().openFile(self.state_path, .{}) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(self.allocator, 64 * 1024);
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

    log.warn("Recovering from crashed pid {d}: restoring UserKeyMapping on {d} device(s) from saved originals", .{ parsed.value.pid, parsed.value.devices.len });
    for (parsed.value.devices) |d| {
        // Make heap-owned copy of original so the AppliedDevice owns it.
        const owned_original = try self.allocator.alloc(ModifierMapping, d.original.len);
        @memcpy(owned_original, d.original);
        try self.applied_devices.append(self.allocator, .{
            .vendor = d.vendor,
            .product = d.product,
            .original = owned_original,
        });
    }
    self.restoreAll();
}

const StateFile = struct {
    pid: i32,
    devices: []StateDevice,
};

const StateDevice = struct {
    vendor: u32,
    product: u32,
    original: []ModifierMapping,
};

fn writeState(self: *Hidutil) !void {
    // Ensure parent dir exists. Errors here are fatal — without the
    // state file we can't recover from a future crash.
    if (std.fs.path.dirname(self.state_path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    var file = try std.fs.cwd().createFile(self.state_path, .{ .truncate = true });
    defer file.close();

    // Build a flattened StateDevice array for serialization (Zig's
    // std.json doesn't auto-coerce AppliedDevice → StateDevice because
    // the field types are owned slices).
    const devices = try self.allocator.alloc(StateDevice, self.applied_devices.items.len);
    defer self.allocator.free(devices);
    for (self.applied_devices.items, 0..) |ad, i| {
        devices[i] = .{ .vendor = ad.vendor, .product = ad.product, .original = ad.original };
    }
    const state = StateFile{
        .pid = @intCast(std.c.getpid()),
        .devices = devices,
    };
    try std.json.stringify(state, .{}, file.writer());
}

fn deleteState(self: *Hidutil) !void {
    std.fs.cwd().deleteFile(self.state_path) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
}

fn resolveStatePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
    return try std.fmt.allocPrint(allocator, "{s}/.cache/skhd/hidutil_state.json", .{home});
}

fn isProcessRunning(pid: i32) bool {
    // kill(pid, 0) returns 0 if process exists and we have permission.
    // -1 with ESRCH means no such process.
    return std.c.kill(pid, 0) == 0;
}

/// Build the merged UserKeyMapping JSON for one device — original
/// entries plus our new ones. Our entries take precedence: any original
/// mapping with the same `src` is dropped from the merge.
fn applyForDevice(allocator: std.mem.Allocator, vendor: u32, product: u32, remaps: []const Mappings.RemapDecl, original: []const ModifierMapping) !void {
    var json_buf = std.ArrayList(u8).init(allocator);
    defer json_buf.deinit();
    const w = json_buf.writer();
    try w.writeAll("{\"UserKeyMapping\":[");

    var first = true;

    // Original entries that don't collide with our new sources.
    for (original) |om| {
        var collides = false;
        for (remaps) |r| {
            if (HidKeyMap.fullUsage(r.src_usage) == om.src) {
                collides = true;
                break;
            }
        }
        if (collides) continue;
        if (!first) try w.writeAll(",");
        try w.print("{{\"HIDKeyboardModifierMappingSrc\":{d},\"HIDKeyboardModifierMappingDst\":{d}}}", .{ om.src, om.dst });
        first = false;
    }

    // Our new entries.
    for (remaps) |r| {
        if (!first) try w.writeAll(",");
        try w.print("{{\"HIDKeyboardModifierMappingSrc\":{d},\"HIDKeyboardModifierMappingDst\":{d}}}", .{ HidKeyMap.fullUsage(r.src_usage), HidKeyMap.fullUsage(r.dst_usage) });
        first = false;
    }

    try w.writeAll("]}");

    var matching_buf: [128]u8 = undefined;
    const matching = try std.fmt.bufPrint(&matching_buf, "{{\"VendorID\":{d},\"ProductID\":{d}}}", .{ vendor, product });

    try runHidutilSet(allocator, matching, json_buf.items);
}

/// SET the device's UserKeyMapping to a literal list (used by restore).
fn setForDevice(allocator: std.mem.Allocator, vendor: u32, product: u32, mappings: []const ModifierMapping) !void {
    var json_buf = std.ArrayList(u8).init(allocator);
    defer json_buf.deinit();
    const w = json_buf.writer();
    try w.writeAll("{\"UserKeyMapping\":[");
    for (mappings, 0..) |m, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"HIDKeyboardModifierMappingSrc\":{d},\"HIDKeyboardModifierMappingDst\":{d}}}", .{ m.src, m.dst });
    }
    try w.writeAll("]}");

    var matching_buf: [128]u8 = undefined;
    const matching = try std.fmt.bufPrint(&matching_buf, "{{\"VendorID\":{d},\"ProductID\":{d}}}", .{ vendor, product });

    try runHidutilSet(allocator, matching, json_buf.items);
}

/// Read the device's current UserKeyMapping by shelling out to
/// `hidutil property --get` and regex-parsing the NSDictionary-format
/// output. Returns a heap-owned slice (caller frees). Empty slice when
/// the device has no UserKeyMapping configured.
fn readExistingMapping(allocator: std.mem.Allocator, vendor: u32, product: u32) ![]ModifierMapping {
    var matching_buf: [128]u8 = undefined;
    const matching = try std.fmt.bufPrint(&matching_buf, "{{\"VendorID\":{d},\"ProductID\":{d}}}", .{ vendor, product });

    var child = std.process.Child.init(&.{
        "/usr/bin/hidutil",
        "property",
        "--matching",
        matching,
        "--get",
        "UserKeyMapping",
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var stdout_data = std.ArrayList(u8).init(allocator);
    defer stdout_data.deinit();
    if (child.stdout) |stdout| stdout.reader().readAllArrayList(&stdout_data, 64 * 1024) catch {};
    if (child.stderr) |stderr| {
        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();
        stderr.reader().readAllArrayList(&sink, 4096) catch {};
    }
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) return error.HidutilGetFailed;

    return parseUserKeyMappings(allocator, stdout_data.items);
}

/// Extract `(src, dst)` integer pairs from hidutil's NSDictionary-text
/// `--get UserKeyMapping` output. The format is loose; we look for
/// `HIDKeyboardModifierMappingSrc = N;` / `Dst = N;` and pair them.
fn parseUserKeyMappings(allocator: std.mem.Allocator, text: []const u8) ![]ModifierMapping {
    var out = std.ArrayList(ModifierMapping).init(allocator);
    errdefer out.deinit();

    var pending_src: ?u64 = null;
    var pending_dst: ?u64 = null;

    var lines = std.mem.tokenizeAny(u8, text, "\n");
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (try findKeyValueU64(line, "HIDKeyboardModifierMappingSrc")) |v| pending_src = v;
        if (try findKeyValueU64(line, "HIDKeyboardModifierMappingDst")) |v| pending_dst = v;
        if (pending_src) |s| {
            if (pending_dst) |d| {
                try out.append(.{ .src = s, .dst = d });
                pending_src = null;
                pending_dst = null;
            }
        }
    }
    return try out.toOwnedSlice();
}

fn findKeyValueU64(line: []const u8, key: []const u8) !?u64 {
    const k_idx = std.mem.indexOf(u8, line, key) orelse return null;
    const after = line[k_idx + key.len ..];
    const eq_idx = std.mem.indexOfScalar(u8, after, '=') orelse return null;
    const val_start = eq_idx + 1;
    var i: usize = val_start;
    while (i < after.len and (after[i] == ' ' or after[i] == '\t')) : (i += 1) {}
    var j: usize = i;
    while (j < after.len and std.ascii.isDigit(after[j])) : (j += 1) {}
    if (j == i) return null;
    return std.fmt.parseInt(u64, after[i..j], 10) catch null;
}

fn runHidutilSet(allocator: std.mem.Allocator, matching: []const u8, set_value: []const u8) !void {
    // Echo the command so a user staring at "nothing happened" can
    // reproduce manually and inspect via `hidutil property --get
    // UserKeyMapping`. Note: hidutil --set returns 0 even when
    // --matching matches zero devices, so a clean exit is not proof of
    // success. The corresponding --get is the real verification.
    log.debug("hidutil property --matching '{s}' --set '{s}'", .{ matching, set_value });

    var child = std.process.Child.init(&.{
        "/usr/bin/hidutil",
        "property",
        "--matching",
        matching,
        "--set",
        set_value,
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var stdout_data = std.ArrayList(u8).init(allocator);
    defer stdout_data.deinit();
    var stderr_data = std.ArrayList(u8).init(allocator);
    defer stderr_data.deinit();
    if (child.stdout) |stdout| stdout.reader().readAllArrayList(&stdout_data, 4096) catch {};
    if (child.stderr) |stderr| stderr.reader().readAllArrayList(&stderr_data, 4096) catch {};
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        log.err("hidutil failed (term={any}): {s}", .{ term, std.mem.trim(u8, stderr_data.items, " \r\n\t") });
        return error.HidutilFailed;
    }
    // hidutil prints the resolved property on success. Empty stdout
    // typically means --matching matched zero devices.
    const trimmed = std.mem.trim(u8, stdout_data.items, " \r\n\t");
    if (trimmed.len == 0) {
        log.warn("hidutil --set returned no output for matching {s}. Likely no device matched (verify with --list-devices).", .{matching});
    } else {
        log.debug("hidutil response: {s}", .{trimmed});
    }
}

test "parseUserKeyMappings extracts src/dst pairs from hidutil --get text" {
    const alloc = std.testing.allocator;
    // Sample shape mirroring real hidutil output, including multi-RegistryID
    // blocks and noise lines.
    const sample =
        \\RegistryID  Key                   Value
        \\10000168a   UserKeyMapping   (
        \\        {
        \\        HIDKeyboardModifierMappingDst = 30064771300;
        \\        HIDKeyboardModifierMappingSrc = 30064771129;
        \\    },
        \\        {
        \\        HIDKeyboardModifierMappingDst = 30064771181;
        \\        HIDKeyboardModifierMappingSrc = 30064771130;
        \\    }
        \\)
    ;
    const result = try parseUserKeyMappings(alloc, sample);
    defer alloc.free(result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(u64, 30064771129), result[0].src);
    try std.testing.expectEqual(@as(u64, 30064771300), result[0].dst);
    try std.testing.expectEqual(@as(u64, 30064771130), result[1].src);
    try std.testing.expectEqual(@as(u64, 30064771181), result[1].dst);
}

test "parseUserKeyMappings handles empty array" {
    const alloc = std.testing.allocator;
    const result = try parseUserKeyMappings(alloc, "10000168a   UserKeyMapping   (\n)\n");
    defer alloc.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}
