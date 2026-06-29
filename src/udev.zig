// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Pierre Dommerc

const std = @import("std");
const c = @import("udev");

fn rc(code: c_int) !void {
    if (code < 0) {
        const err: std.posix.E = @enumFromInt(-code);
        std.log.err("c error: {}", .{err});
        return error.Cerr;
    }
}

pub const Udev = struct {
    ctx: *c.udev,
    monitor: *c.udev_monitor,
    fd: c_int,

    const Self = @This();

    pub fn init() !Self {
        const ctx = c.udev_new() orelse return error.UdevNew;
        errdefer _ = c.udev_unref(ctx);
        const monitor = c.udev_monitor_new_from_netlink(ctx, "udev") orelse return error.UdevMonNew;
        errdefer _ = c.udev_monitor_unref(monitor);
        rc(c.udev_monitor_filter_add_match_subsystem_devtype(monitor, "power_supply", null)) catch return error.UdevMonFilterAdd;
        rc(c.udev_monitor_enable_receiving(monitor)) catch return error.UdevMonEnableReceiving;
        const fd = c.udev_monitor_get_fd(monitor);
        rc(fd) catch return error.UdevMonGetFd;

        return Udev{
            .ctx = ctx,
            .monitor = monitor,
            .fd = fd,
        };
    }

    pub fn getAcOnline(self: *Self) !?bool {
        const dev = c.udev_monitor_receive_device(self.monitor) orelse
            return null;
        defer _ = c.udev_device_unref(dev);

        const action = c.udev_device_get_action(dev) orelse return null;
        if (!std.mem.eql(u8, std.mem.span(action), "change")) return null;
        const property = c.udev_device_get_property_value(dev, "POWER_SUPPLY_ONLINE") orelse
            return null;
        const val = std.mem.span(property);
        if (std.mem.eql(u8, val, "1")) {
            return true;
        } else if (std.mem.eql(u8, val, "0")) {
            return false;
        } else {
            std.log.err("udev ac event unexpected value: '{s}'", .{ val });
            return error.UdevAcEventParse;
        }
    }

    pub fn deinit(self: *Self) void {
        _ = c.udev_monitor_unref(self.monitor);
        _ = c.udev_unref(self.ctx);
    }
};
