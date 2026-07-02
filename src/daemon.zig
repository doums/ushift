// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Pierre Dommerc

const std = @import("std");
const fs = @import("fs.zig");
const pws = @import("power_supply.zig");
const Udev = @import("udev.zig").Udev;
const Profile = @import("cli.zig").Profile;
const DaemonProps = @import("cli.zig").DaemonProps;
const UserConfig = @import("config.zig").UserConfig;
const Cpu = @import("cpu.zig").Cpu;
const Gpu = @import("gpu.zig").Gpu;

pub const Daemon = struct {
    dry_run: bool = false,
    // ------
    cpu: *const Cpu,
    gpu: *const Gpu,
    // ------
    bat: []u8, // sysfs device name
    ac: []u8,
    sysfs_cap_prefix: pws.BatteryCapacityPrefix,
    poll_timeout: u32,
    low_level: u32,
    performance_profile: *const Profile,
    balance_profile: *const Profile,
    save_profile: ?*const Profile,
    // state
    ac_online: bool,
    bat_cap: u32 = 100,
    bat_low: bool,

    const Self = @This();
    var _gpa: std.mem.Allocator = undefined;
    var _io: std.Io = undefined;

    pub fn init(gpa: std.mem.Allocator, io: std.Io, data: struct {
        cpu: *const Cpu,
        gpu: *const Gpu,
        flags: DaemonProps,
        config: *const UserConfig,
    }) !Self {
        _gpa = gpa;
        _io = io;
        const cfg = data.config;
        const flags = data.flags;

        const ps = try pws.getPowerSupply(gpa, io, true);
        var user_bat: ?[]u8 = null;
        errdefer {
            if (user_bat == null) gpa.free(ps.bat);
            gpa.free(ps.ac);
            if (user_bat) |v| gpa.free(v);
        }

        if (flags.bat_name orelse cfg.battery_name) |bat| {
            if (!try pws.checkUserBattery(io, bat)) return error.InvalidUserBattery;
            // let's clone it so we can free later without caring
            user_bat = try gpa.dupe(u8, bat);
            gpa.free(ps.bat);
        }
        const battery = user_bat orelse ps.bat;
        const low_level = flags.bat_low orelse cfg.battery_low;
        std.log.info("using battery: {s}", .{battery});

        const cap_prefix = try pws.getBatteryCapacityPrefix(io, battery);
        std.log.debug("sysfs battery capacity prefix: {s}", .{@tagName(cap_prefix)});

        // init AC state
        const ac_online = try pws.readAcOnline(io, ps.ac);
        std.log.debug("AC online: {}", .{ac_online});

        if (data.gpu.cards.len == 0) {
            std.log.warn("no GPU card found", .{});
        } else for (data.gpu.cards) |card| card.print(.{ .logger = .log });

        var bat_cap: u32 = 100;
        var bat_low = false;
        if (cfg.save) |_| {
            // init battery level state
            bat_cap = try pws.readBatteryCapacity(io, battery, cap_prefix);
            bat_low = bat_cap <= low_level;
            std.log.debug("battery low: {} (low level: {d}%)", .{
                bat_low,
                low_level,
            });
        } else {
            std.log.info("no save profile defined in config, ignoring battery level", .{});
        }

        return Daemon{
            .dry_run = flags.dry_run,
            .cpu = data.cpu,
            .gpu = data.gpu,
            .bat = battery,
            .ac = ps.ac,
            .sysfs_cap_prefix = cap_prefix,
            .poll_timeout = flags.poll_rate orelse cfg.battery_poll_rate,
            .low_level = low_level,
            .performance_profile = &cfg.performance,
            .balance_profile = &cfg.balance,
            .save_profile = if (cfg.save) |*save| save else null,
            .ac_online = ac_online,
            .bat_cap = bat_cap,
            .bat_low = bat_low,
        };
    }

    pub fn run(self: *Self) !void {
        var udev = try Udev.init();
        defer udev.deinit();

        var fds = [_]std.posix.pollfd{.{
            .fd = udev.fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const timeout = if (self.save_profile) |_|
            &std.posix.timespec{ .sec = self.poll_timeout, .nsec = 0 }
        else
            null;

        // init before entering the loop, so we don't have to wait for the first tick
        try self.switchProfile(self.ac_online, self.bat_low);

        installSigHandler();

        while (true) {
            const pr = std.posix.ppoll(&fds, timeout, null) catch |err| switch (err) {
                error.SignalInterrupt => {
                    std.log.warn("caught signal exiting", .{});
                    break;
                },
                else => {
                    std.log.err("poll error: {s}", .{@errorName(err)});
                    return error.DaemonPoll;
                },
            };

            // on poll timeout -> read battery level
            if (pr == 0 and self.save_profile != null) {
                std.log.debug("_", .{});
                try self.handleTick();
                continue;
            }

            // on udev event -> new AC state
            const online = try udev.getAcOnline() orelse continue;
            if (self.ac_online != online) {
                std.log.info("AC online: {}", .{online});
                self.ac_online = online;
                if (self.save_profile) |_| try self.refreshBatteryLevel();
                self.switchProfile(online, self.bat_low) catch |err| {
                    std.log.err("failed to switch profile: {s}", .{@errorName(err)});
                    return err;
                };
            }
        }
    }

    fn handleTick(self: *Self) !void {
        const capacity = try pws.readBatteryCapacity(_io, self.bat, self.sysfs_cap_prefix);
        if (self.bat_cap != capacity) {
            std.log.debug("battery level: {d}% -> {d}%", .{ self.bat_cap, capacity });
            self.bat_cap = capacity;
        }
        const bat_low = capacity <= self.low_level;
        if (self.bat_low != bat_low) {
            std.log.info("battery low: {} -> {}", .{ self.bat_low, bat_low });
            self.bat_low = bat_low;
            self.switchProfile(self.ac_online, bat_low) catch |err| {
                std.log.err("failed to switch profile: {s}", .{@errorName(err)});
                return err;
            };
        }
    }

    fn switchProfile(self: *const Self, new_ac_online: bool, new_low_battery: bool) !void {
        std.log.debug("ac online: {} (low battery: {})", .{ new_ac_online, new_low_battery });
        if (new_ac_online) {
            std.log.info("switching profile [performance]", .{});
            try self.setCpuAndGpuProfile(self.performance_profile);
            return;
        }
        if (new_low_battery) if (self.save_profile) |save| {
            std.log.info("switching profile [save]", .{});
            try self.setCpuAndGpuProfile(save);
            return;
        };
        std.log.info("switching profile [balance]", .{});
        try self.setCpuAndGpuProfile(self.balance_profile);
    }

    fn setCpuAndGpuProfile(self: *const Self, profile: *const Profile) !void {
        if (self.dry_run) {
            std.log.info("[DRY-RUN] would set profile: {any}", .{profile});
            return;
        }
        try self.cpu.setProfile(profile);
        try self.gpu.setProfile(profile);
    }

    fn refreshBatteryLevel(self: *Self) !void {
        const level = try pws.readBatteryCapacity(_io, self.bat, self.sysfs_cap_prefix);
        self.bat_cap = level;
        self.bat_low = level <= self.low_level;
    }

    pub fn deinit(self: *const Self) void {
        _gpa.free(self.bat);
        _gpa.free(self.ac);
    }
};

// Install no-op handlers for SIGTERM and SIGINT so that delivering either signal
// causes ppoll() to return EINTR (aka error.SignalInterrupt)
// instead of terminating the process via the default action
fn installSigHandler() void {
    const noop = struct {
        fn handler(_: std.posix.SIG) callconv(.c) void {}
    }.handler;
    const sa = std.posix.Sigaction{
        .handler = .{ .handler = noop },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    // override the default handlers
    std.posix.sigaction(.TERM, &sa, null);
    std.posix.sigaction(.INT, &sa, null);
}
