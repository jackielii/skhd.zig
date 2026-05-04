/// Thin Zig bridge to Apple's `SMAppService` Obj-C class (ServiceManagement
/// framework, macOS 13+). Required for registering the bundled LaunchAgent
/// with the Background Tasks Manager (BTM) on Sequoia/Tahoe — the legacy
/// `~/Library/LaunchAgents/` flow is silently `disallowed` by BTM until the
/// user manually approves it in System Settings → Login Items & Extensions,
/// which manifests as "skhd doesn't always start after reboot".
///
/// SMAppService binds to the *calling* app bundle. The plist must live at
/// `<App>.app/Contents/Library/LaunchAgents/<plistName>` — see make-app.sh.
const std = @import("std");
const c = @import("c.zig");
const log = std.log.scoped(.sm_app_service);

/// `SMAppServiceStatus` enum (NSInteger). See <ServiceManagement/SMAppService.h>.
pub const Status = enum(c_long) {
    not_registered = 0,
    enabled = 1,
    requires_approval = 2,
    not_found = 3,
    _,

    pub fn describe(self: Status) []const u8 {
        return switch (self) {
            .not_registered => "not registered",
            .enabled => "enabled",
            .requires_approval => "requires user approval in System Settings → Login Items & Extensions",
            .not_found => "bundled plist not found",
            _ => "unknown",
        };
    }
};

/// Opaque Obj-C reference to an SMAppService instance.
pub const Service = c.id;

const NullService = error.SMAppServiceUnavailable;

/// Build an NSString from a null-terminated UTF-8 C string. Returned object
/// is autoreleased; we don't manage its lifetime explicitly because each
/// call site does a single `+stringWithUTF8String:` that's only used as an
/// argument to one subsequent message-send.
fn nsString(utf8: [*:0]const u8) c.id {
    const NSStringClass = c.objc_getClass("NSString") orelse return null;
    const sel = c.sel_registerName("stringWithUTF8String:");
    const msg = @extern(
        *const fn (c.id, c.SEL, [*:0]const u8) callconv(.c) c.id,
        .{ .name = "objc_msgSend" },
    );
    return msg(@as(c.id, @ptrCast(@alignCast(NSStringClass))), sel, utf8);
}

/// Equivalent to `[SMAppService agentServiceWithPlistName:plistName]`.
/// Returns null when the SMAppService class isn't available (i.e. we're
/// running on macOS < 13, which we don't support but failing soft beats
/// crashing).
pub fn agentService(plist_name: [*:0]const u8) ?Service {
    const SMAppServiceClass = c.objc_getClass("SMAppService") orelse {
        log.err("SMAppService class is not available (macOS 13+ required)", .{});
        return null;
    };
    const sel = c.sel_registerName("agentServiceWithPlistName:");
    const msg = @extern(
        *const fn (c.id, c.SEL, c.id) callconv(.c) c.id,
        .{ .name = "objc_msgSend" },
    );
    const plist_ns = nsString(plist_name);
    return msg(@as(c.id, @ptrCast(@alignCast(SMAppServiceClass))), sel, plist_ns);
}

/// Equivalent to `service.status` — see `Status` for values.
pub fn status(service: Service) Status {
    const sel = c.sel_registerName("status");
    const msg = @extern(
        *const fn (c.id, c.SEL) callconv(.c) c_long,
        .{ .name = "objc_msgSend" },
    );
    return @enumFromInt(msg(service, sel));
}

/// Equivalent to `try service.register()` — returns RegisterFailed on
/// failure with the localized error message logged.
pub fn register(service: Service) !void {
    const sel = c.sel_registerName("registerAndReturnError:");
    // Use u8 instead of c.BOOL: on arm64-darwin BOOL translates to bool
    // (Zig type), on x86_64-darwin it translates to i8 (signed char). Both
    // are 1-byte on the Darwin ABI, so u8 marshals correctly on either.
    const msg = @extern(
        *const fn (c.id, c.SEL, *c.id) callconv(.c) u8,
        .{ .name = "objc_msgSend" },
    );
    var err: c.id = null;
    const ok = msg(service, sel, &err);
    if (ok == 0) {
        if (err) |e| logNSError("SMAppService.register", e) else log.err("SMAppService.register failed (no error info)", .{});
        return error.RegisterFailed;
    }
}

/// Equivalent to `try service.unregister()`.
pub fn unregister(service: Service) !void {
    const sel = c.sel_registerName("unregisterAndReturnError:");
    const msg = @extern(
        *const fn (c.id, c.SEL, *c.id) callconv(.c) u8,
        .{ .name = "objc_msgSend" },
    );
    var err: c.id = null;
    const ok = msg(service, sel, &err);
    if (ok == 0) {
        if (err) |e| logNSError("SMAppService.unregister", e) else log.err("SMAppService.unregister failed (no error info)", .{});
        return error.UnregisterFailed;
    }
}

/// Read `error.localizedDescription.UTF8String` and forward to our log.
fn logNSError(prefix: []const u8, err: c.id) void {
    const sel_desc = c.sel_registerName("localizedDescription");
    const desc_msg = @extern(
        *const fn (c.id, c.SEL) callconv(.c) c.id,
        .{ .name = "objc_msgSend" },
    );
    const desc = desc_msg(err, sel_desc);
    if (desc == null) {
        log.err("{s} failed (no localized description)", .{prefix});
        return;
    }

    const sel_utf8 = c.sel_registerName("UTF8String");
    const utf8_msg = @extern(
        *const fn (c.id, c.SEL) callconv(.c) ?[*:0]const u8,
        .{ .name = "objc_msgSend" },
    );
    const utf8 = utf8_msg(desc, sel_utf8) orelse {
        log.err("{s} failed (UTF8String returned null)", .{prefix});
        return;
    };
    log.err("{s} failed: {s}", .{ prefix, std.mem.span(utf8) });
}
