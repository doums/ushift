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
const PowerSupply = @import("power_supply.zig").PowerSupply;
const Battery = @import("power_supply.zig").Battery;
const Ac = @import("power_supply.zig").Ac;

pub const Daemon = struct {
    dry_run: bool = false,
    // ------
    cpu: *const Cpu,
    gpu: *const Gpu,
    power_supply: pws.PowerSupply,
    // ------
    bat: *const Battery,
    ac: *const Ac,
    poll_timeout: u32,
    low_level: u32,
    performance_profile: *const Profile,
    balance_profile: *const Profile,
    charge_thresh_start: ?u32,
    charge_thresh_end: ?u32,
    restore_charge_thresh_on_bat: bool,
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

        var ps = try PowerSupply.init(gpa, io, true);
        errdefer ps.deinit(gpa);

        if (ps.batteries.len == 0) {
            std.log.err("no battery found", .{});
            return error.NoBatteryFound;
        }
        if (ps.aces.len == 0) {
            std.log.err("no AC adapter found", .{});
            return error.NoAcFound;
        }

        const battery = if (flags.bat_name orelse cfg.battery_name) |bat|
            ps.getBattery(bat) orelse {
                std.log.err("battery '{s}' not found", .{bat});
                return error.InvalidUserBattery;
            }
        else
            &ps.batteries[0];
        std.log.info("using battery: {s}", .{battery.name});

        try initBatChargeThresholds(io, .{
            .battery = battery,
            .start = cfg.battery_start_charge_threshold,
            .end = cfg.battery_end_charge_threshold,
            .dry_run = flags.dry_run,
        });

        // init AC state
        const ac = &ps.aces[0];
        const ac_online = try ac.readOnline(io);
        std.log.info("using AC: {s}", .{ac.name});
        std.log.debug("AC online: {}", .{ac_online});

        if (data.gpu.cards.len == 0) {
            std.log.warn("no GPU card found", .{});
        } else for (data.gpu.cards) |card| card.print(.{ .logger = .log });

        var bat_cap: u32 = 100;
        var bat_low = false;
        const low_level = flags.bat_low orelse cfg.battery_low;
        if (cfg.save) |_| {
            // init battery level state
            bat_cap = try battery.readCapacity(io);
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
            .power_supply = ps,
            .bat = battery,
            .ac = ac,
            .poll_timeout = flags.poll_rate orelse cfg.battery_poll_rate,
            .low_level = low_level,
            .charge_thresh_start = cfg.battery_start_charge_threshold,
            .charge_thresh_end = cfg.battery_end_charge_threshold,
            .restore_charge_thresh_on_bat = cfg.restore_charge_thresholds_on_bat,
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

                if (self.restore_charge_thresh_on_bat and
                    !online and
                    self.bat.charge_threshold_prefix != null)
                {
                    if (self.dry_run) {
                        std.log.info(
                            "[DRY-RUN] would restore battery charge thresholds: start={?d}, end={?d}",
                            .{ self.charge_thresh_start, self.charge_thresh_end },
                        );
                    } else {
                        std.log.info("restoring battery charge thresholds", .{});
                        self.bat.setChargeThreshold(
                            _io,
                            self.charge_thresh_start,
                            self.charge_thresh_end,
                        ) catch |err| {
                            std.log.err("failed to restore battery charge thresholds: {s}", .{@errorName(err)});
                        };
                    }
                }
            }
        }
    }

    fn handleTick(self: *Self) !void {
        const capacity = try self.bat.readCapacity(_io);
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
        const level = try self.bat.readCapacity(_io);
        self.bat_cap = level;
        self.bat_low = level <= self.low_level;
    }

    pub fn deinit(self: *Self) void {
        self.power_supply.deinit(_gpa);
    }
};

fn initBatChargeThresholds(io: std.Io, data: struct {
    battery: *const Battery,
    start: ?u32,
    end: ?u32,
    dry_run: bool,
}) !void {
    const bat = data.battery;
    const start = data.start;
    const end = data.end;

    if (start == null and end == null) return;

    if (start) |s| if (s > 99 or s == 0)
        return error.InvalidBatteryStartChargeThreshold;
    if (end) |e| if (e > 100 or e == 0)
        return error.InvalidBatteryEndChargeThreshold;
    if (start) |s| if (end) |e|
        if (s >= e)
            return error.InvalidBatteryChargeThreshold;

    if (bat.charge_threshold_prefix == null) {
        std.log.warn(
            "battery charge thresholds not supported for battery '{s}', ignoring",
            .{bat.name},
        );
    } else if (data.dry_run) {
        std.log.info(
            "[DRY-RUN] would set battery '{s}' charge thresholds: start={?d}, end={?d}",
            .{ bat.name, start, end },
        );
    } else {
        std.log.info(
            "setting battery '{s}' charge thresholds: start={?d}, end={?d}",
            .{ bat.name, start, end },
        );
        try bat.setChargeThreshold(io, start, end);
    }
}

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
