const std = @import("std");
const c = @import("c.zig");

const DeviceManager = @This();
const log = std.log.scoped(.device_manager);

// Helper to create CFString constants
fn createCFString(str: [*c]const u8) c.CFStringRef {
    return c.CFStringCreateWithCString(c.kCFAllocatorDefault, str, c.kCFStringEncodingUTF8);
}

pub const DeviceType = enum {
    keyboard,
    mouse,
    other,
};

pub const DeviceInfo = struct {
    vendor_id: u32,
    product_id: u32,
    name: []const u8,
    location_id: u32,
    unique_id: u64, // Session-based unique identifier
    device_type: DeviceType,
    registry_id: u64, // IORegistry entry ID for linking with CGEvent
};

allocator: std.mem.Allocator,
hid_manager: c.IOHIDManagerRef,
devices: std.AutoHashMap(c.IOHIDDeviceRef, DeviceInfo),
next_unique_id: u64 = 1,

pub fn create(allocator: std.mem.Allocator) !*DeviceManager {
    const hid_manager = c.IOHIDManagerCreate(c.kCFAllocatorDefault, c.kIOHIDOptionsTypeNone);
    if (hid_manager == null) {
        return error.HIDManagerCreateFailed;
    }

    const self = try allocator.create(DeviceManager);
    self.* = DeviceManager{
        .allocator = allocator,
        .hid_manager = hid_manager,
        .devices = std.AutoHashMap(c.IOHIDDeviceRef, DeviceInfo).init(allocator),
    };

    // Set up device matching for all HID devices on the Generic Desktop page
    // This includes keyboards, mice, joysticks, etc.
    const usage_page_num = c.kHIDPage_GenericDesktop;
    const usage_page = c.CFNumberCreate(c.kCFAllocatorDefault, c.kCFNumberIntType, &usage_page_num);
    defer c.CFRelease(usage_page);

    const usage_page_key = createCFString(c.kIOHIDDeviceUsagePageKey);
    defer c.CFRelease(usage_page_key);

    const matching_dict = c.CFDictionaryCreateMutable(c.kCFAllocatorDefault, 0, &c.kCFTypeDictionaryKeyCallBacks, &c.kCFTypeDictionaryValueCallBacks);
    c.CFDictionarySetValue(matching_dict, usage_page_key, usage_page);
    c.IOHIDManagerSetDeviceMatching(hid_manager, matching_dict);
    c.CFRelease(matching_dict);

    // Register callbacks
    c.IOHIDManagerRegisterDeviceMatchingCallback(hid_manager, deviceAddedCallback, @ptrCast(self));
    c.IOHIDManagerRegisterDeviceRemovalCallback(hid_manager, deviceRemovedCallback, @ptrCast(self));

    // Schedule with run loop
    c.IOHIDManagerScheduleWithRunLoop(hid_manager, c.CFRunLoopGetCurrent(), c.kCFRunLoopDefaultMode);

    // Open the HID manager
    const result = c.IOHIDManagerOpen(hid_manager, c.kIOHIDOptionsTypeNone);
    if (result != c.kIOReturnSuccess) {
        c.CFRelease(hid_manager);
        return error.HIDManagerOpenFailed;
    }

    // Enumerate already connected devices
    const device_set = c.IOHIDManagerCopyDevices(hid_manager);
    if (device_set) |set| {
        defer c.CFRelease(set);
        const count = c.CFSetGetCount(set);
        if (count > 0) {
            const devices = try allocator.alloc(c.IOHIDDeviceRef, @intCast(count));
            defer allocator.free(devices);
            c.CFSetGetValues(set, @ptrCast(devices.ptr));
            for (devices) |device| {
                try self.addDevice(device);
            }
        }
    }

    return self;
}

pub fn destroy(self: *DeviceManager) void {
    // Unregister callbacks first
    c.IOHIDManagerRegisterDeviceMatchingCallback(self.hid_manager, null, null);
    c.IOHIDManagerRegisterDeviceRemovalCallback(self.hid_manager, null, null);

    // Clean up device info
    var iter = self.devices.iterator();
    while (iter.next()) |entry| {
        self.allocator.free(entry.value_ptr.name);
    }
    self.devices.deinit();

    // Close and release HID manager
    _ = c.IOHIDManagerClose(self.hid_manager, c.kIOHIDOptionsTypeNone);
    c.IOHIDManagerUnscheduleFromRunLoop(self.hid_manager, c.CFRunLoopGetCurrent(), c.kCFRunLoopDefaultMode);
    c.CFRelease(self.hid_manager);

    // Free self
    self.allocator.destroy(self);
}

fn deviceAddedCallback(context: ?*anyopaque, _: c.IOReturn, _: ?*anyopaque, device: c.IOHIDDeviceRef) callconv(.c) void {
    const self = @as(*DeviceManager, @ptrCast(@alignCast(context)));
    self.addDevice(device) catch |err| {
        log.err("Failed to add device: {}", .{err});
    };
}

fn deviceRemovedCallback(context: ?*anyopaque, _: c.IOReturn, _: ?*anyopaque, device: c.IOHIDDeviceRef) callconv(.c) void {
    const self = @as(*DeviceManager, @ptrCast(@alignCast(context)));
    self.removeDevice(device);
}

fn addDevice(self: *DeviceManager, device: c.IOHIDDeviceRef) !void {
    // Check if this is actually a keyboard
    const usage_page_key = createCFString(c.kIOHIDPrimaryUsagePageKey);
    const usage_key = createCFString(c.kIOHIDPrimaryUsageKey);
    defer c.CFRelease(usage_page_key);
    defer c.CFRelease(usage_key);

    var device_type = DeviceType.other;
    var is_hid_device = false;

    if (c.IOHIDDeviceGetProperty(device, usage_page_key)) |page_ref| {
        var usage_page: i32 = 0;
        if (c.CFNumberGetValue(@ptrCast(page_ref), c.kCFNumberSInt32Type, &usage_page) != 0) {
            if (usage_page == c.kHIDPage_GenericDesktop) {
                if (c.IOHIDDeviceGetProperty(device, usage_key)) |usage_ref| {
                    var usage: i32 = 0;
                    if (c.CFNumberGetValue(@ptrCast(usage_ref), c.kCFNumberSInt32Type, &usage) != 0) {
                        if (usage == c.kHIDUsage_GD_Keyboard) {
                            device_type = DeviceType.keyboard;
                            is_hid_device = true;
                        } else if (usage == c.kHIDUsage_GD_Mouse) {
                            device_type = DeviceType.mouse;
                            is_hid_device = true;
                        }
                        log.debug("Device usage: {} ({s})", .{ usage, @tagName(device_type) });
                    }
                }
            }
        }
    }

    // Get product name first for logging
    const product_name_key = createCFString(c.kIOHIDProductKey);
    defer c.CFRelease(product_name_key);
    var device_name_buffer: ?[]u8 = null;
    defer if (device_name_buffer) |buf| self.allocator.free(buf);

    var device_name: []const u8 = "Unknown";
    if (c.IOHIDDeviceGetProperty(device, product_name_key)) |name_ref| {
        const cf_str = @as(c.CFStringRef, @ptrCast(name_ref));
        const length = c.CFStringGetLength(cf_str);
        const max_size = c.CFStringGetMaximumSizeForEncoding(length, c.kCFStringEncodingUTF8) + 1;
        device_name_buffer = self.allocator.alloc(u8, @intCast(max_size)) catch {
            if (!is_hid_device) return;
            return error.OutOfMemory;
        };

        if (c.CFStringGetCString(cf_str, device_name_buffer.?.ptr, @intCast(max_size), c.kCFStringEncodingUTF8) != 0) {
            const actual_len = std.mem.sliceTo(device_name_buffer.?, 0).len;
            device_name = device_name_buffer.?[0..actual_len];
        }
    }

    if (!is_hid_device) {
        log.debug("Skipping non-HID device: {s}", .{device_name});
        return;
    }

    var info = DeviceInfo{
        .vendor_id = 0,
        .product_id = 0,
        .name = "",
        .location_id = 0,
        .unique_id = self.next_unique_id,
        .device_type = device_type,
        .registry_id = 0,
    };
    self.next_unique_id += 1;

    // Get registry entry ID
    const registry_id = c.IOHIDDeviceGetRegistryEntryID(@ptrCast(device));
    log.debug("IOHIDDeviceGetRegistryEntryID returned: {} for device: {s}", .{ registry_id, device_name });
    if (registry_id != 0) {
        info.registry_id = registry_id;
    }

    // Get vendor ID
    const vendor_key = createCFString(c.kIOHIDVendorIDKey);
    defer c.CFRelease(vendor_key);
    if (c.IOHIDDeviceGetProperty(device, vendor_key)) |vendor_ref| {
        var vendor_id: i32 = 0;
        if (c.CFNumberGetValue(@ptrCast(vendor_ref), c.kCFNumberSInt32Type, &vendor_id) != 0) {
            info.vendor_id = @intCast(vendor_id);
        }
    }

    // Get product ID
    const product_key = createCFString(c.kIOHIDProductIDKey);
    defer c.CFRelease(product_key);
    if (c.IOHIDDeviceGetProperty(device, product_key)) |product_ref| {
        var product_id: i32 = 0;
        if (c.CFNumberGetValue(@ptrCast(product_ref), c.kCFNumberSInt32Type, &product_id) != 0) {
            info.product_id = @intCast(product_id);
        }
    }

    // Get location ID
    const location_key = createCFString(c.kIOHIDLocationIDKey);
    defer c.CFRelease(location_key);
    if (c.IOHIDDeviceGetProperty(device, location_key)) |location_ref| {
        var location_id: i32 = 0;
        if (c.CFNumberGetValue(@ptrCast(location_ref), c.kCFNumberSInt32Type, &location_id) != 0) {
            info.location_id = @bitCast(location_id);
        }
    }

    // Duplicate the device name for storage
    info.name = try self.allocator.dupe(u8, device_name);

    try self.devices.put(device, info);
    log.info("Added {s}: {} - {s} (0x{x:0>4}:0x{x:0>4})", .{ @tagName(info.device_type), info.unique_id, info.name, info.vendor_id, info.product_id });
}

fn removeDevice(self: *DeviceManager, device: c.IOHIDDeviceRef) void {
    if (self.devices.fetchRemove(device)) |entry| {
        log.info("Removed {s}: {} - {s}", .{ @tagName(entry.value.device_type), entry.value.unique_id, entry.value.name });
        self.allocator.free(entry.value.name);
    }
}

pub fn getDeviceInfo(self: *DeviceManager, device: c.IOHIDDeviceRef) ?DeviceInfo {
    return self.devices.get(device);
}

pub fn getKeyboardDevices(self: *DeviceManager) []const DeviceInfo {
    var keyboards = std.ArrayList(DeviceInfo).init(self.allocator);
    defer keyboards.deinit();

    var iter = self.devices.iterator();
    while (iter.next()) |entry| {
        keyboards.append(entry.value_ptr.*) catch continue;
    }

    return keyboards.toOwnedSlice() catch &[_]DeviceInfo{};
}

pub fn findDeviceByLocationId(self: *DeviceManager, location_id: u32) ?c.IOHIDDeviceRef {
    var iter = self.devices.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.location_id == location_id) {
            return entry.key_ptr.*;
        }
    }
    return null;
}

pub fn findDeviceByRegistryId(self: *DeviceManager, registry_id: u64) ?DeviceInfo {
    var iter = self.devices.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.registry_id == registry_id) {
            return entry.value_ptr.*;
        }
    }
    return null;
}

// Get device from CGEvent using undocumented field 87 which contains registry ID
pub fn getDeviceFromEvent(self: *DeviceManager, event: c.CGEventRef) ?DeviceInfo {
    // Try multiple fields that might contain device information
    const fields_to_try = [_]c.CGEventField{
        87,  // Known to contain device registry ID in some cases
        88,  // Adjacent field that might have related info
        89,  // Another adjacent field
        120, // Another potential field mentioned in some sources
        96,  // Another undocumented field
        97,  // Adjacent to 96
        17,  // kCGKeyboardEventKeyboardType
    };
    
    for (fields_to_try) |field| {
        const value = c.CGEventGetIntegerValueField(event, field);
        if (value != 0) {
            log.debug("CGEvent field {} value: {}", .{ field, value });
            
            // Try exact match first
            const found_device = self.findDeviceByRegistryId(@intCast(value));
            if (found_device != null) {
                log.debug("Found matching device using field {}: {s}", .{ field, found_device.?.name });
                return found_device;
            }
            
            // If field 87, also try to find device within a small range (±100)
            if (field == 87) {
                var best_match: ?DeviceInfo = null;
                var best_diff: i64 = 101;
                
                var iter = self.devices.iterator();
                while (iter.next()) |entry| {
                    const device_reg_id = @as(i64, @intCast(entry.value_ptr.registry_id));
                    const diff = if (value > device_reg_id) value - device_reg_id else device_reg_id - value;
                    if (diff <= 100) {
                        log.debug("Found device within range (diff={}): {s} ({s})", .{ diff, entry.value_ptr.name, @tagName(entry.value_ptr.device_type) });
                        
                        // Prefer keyboard devices for key events
                        if (diff < best_diff) {
                            best_match = entry.value_ptr.*;
                            best_diff = diff;
                        } else if (diff == best_diff and entry.value_ptr.device_type == .keyboard and best_match != null and best_match.?.device_type != .keyboard) {
                            // If same distance, prefer keyboard over mouse
                            best_match = entry.value_ptr.*;
                        }
                    }
                }
                
                if (best_match) |device| {
                    log.debug("Selected best match: {s} (diff={})", .{ device.name, best_diff });
                    return device;
                }
            }
        }
    }
    
    // If no match found, log all our known devices
    log.debug("No device match found. Known devices:", .{});
    var iter = self.devices.iterator();
    while (iter.next()) |entry| {
        log.debug("  Device: {s} has registry_id: {}", .{ entry.value_ptr.name, entry.value_ptr.registry_id });
    }
    
    return null;
}

pub fn registerInputCallbacks(self: *DeviceManager, callback: c.IOHIDValueCallback, context: ?*anyopaque) !void {
    var iter = self.devices.iterator();
    while (iter.next()) |entry| {
        const device = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        if (info.device_type == .keyboard) {
            // Register input value callback for this keyboard
            c.IOHIDDeviceRegisterInputValueCallback(device, callback, context);

            // Open the device
            const result = c.IOHIDDeviceOpen(device, c.kIOHIDOptionsTypeNone);
            if (result != c.kIOReturnSuccess) {
                log.warn("Failed to open device: {s}", .{info.name});
            }
        }
    }
}

test "DeviceManager basic operations" {
    const allocator = std.testing.allocator;
    var manager = try DeviceManager.create(allocator);
    defer manager.destroy();

    // The manager should initialize successfully
    // Actual device enumeration would happen in real usage
}
