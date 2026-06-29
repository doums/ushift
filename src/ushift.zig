// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Pierre Dommerc

const std = @import("std");
const cli = @import("cli.zig");
const pws = @import("power_supply.zig");
const Daemon = @import("daemon.zig").Daemon;
const Cpu = @import("cpu.zig").Cpu;
const Gpu = @import("gpu.zig").Gpu;
const UserConfig = @import("config.zig").UserConfig;
const Profile = @import("cli.zig").Profile;

pub const Ushift = struct {
    cpu: Cpu,

    var _gpa: std.mem.Allocator = undefined;
    var _io: std.Io = undefined;

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !Self {
        _gpa = gpa;
        _io = io;
        const cpu = try Cpu.init(gpa, io);

        return Self{
            .cpu = cpu,
        };
    }

    pub fn dispatch(self: *const Self, parsed: cli.Parsed, config: *const UserConfig) !void {
        // only initialize GPU if needed
        var gpu: ?Gpu = null;
        if (needGpuLookup(&parsed, config)) {
            gpu = try Gpu.init(_gpa, _io);
        }
        defer if (gpu) |*g| g.deinit();

        var err_hit: usize = 0;
        switch (parsed) {
            .get => |props| {
                if (props.driver) |_| self.cpu.printDriver() catch {};
                if (props.op_mode) |_| self.cpu.printPstateOpMode() catch {};
                if (props.scaling_governor) |_| self.cpu.printScalingGovernor() catch {};
                if (props.energy_perf_policy) |_| self.cpu.printEnergyPerformancePolicy() catch {};
                if (props.turbo_boost) |_| self.cpu.printTurboBoost() catch {};
                if (props.hwp_dyn_boost) |_| self.cpu.printIntelDynBoost() catch {};
                if (props.xe_power_profile) |xe| gpu.?.printXePowerProfile(xe.gpu_index) catch {};
            },
            .set => |props| {
                try hasRoot();
                err_hit = self.runBatch(&props, &gpu);
            },
            .set_profile => |opt| {
                try hasRoot();
                const profile = switch (opt.profile) {
                    .performance => config.performance,
                    .balance => config.balance,
                    .save => config.save,
                } orelse {
                    std.log.err("profile '{s}' not defined in config", .{@tagName(opt.profile)});
                    return error.ProfileNotDefined;
                };
                self.cpu.setProfile(&profile) catch {
                    err_hit += 1;
                };
                if (gpu) |g|
                    g.setProfile(&profile, config.gpu_index) catch {
                        err_hit += 1;
                    };
            },
            .info => |kind| switch (kind) {
                .cpu => self.cpu.print(),
                .gpu => if (gpu) |g| g.print() else unreachable,
            },
            .power_supply => pws.printPowerSupply(_gpa, _io) catch {
                // TODO handle absence of battery or AC gracefully
                // ie. on desktop
            },
            .daemon => |flags| {
                try hasRoot();
                var d = try Daemon.init(_gpa, _io, .{
                    .cpu = &self.cpu,
                    .gpu = if (gpu) |*g| g else null,
                    .flags = flags,
                    .config = config,
                });
                defer d.deinit();
                try d.run();
            },
            else => unreachable,
        }
        if (err_hit == 1) {
            return error.CommandError;
        } else if (err_hit > 1) {
            return error.CommandErrors;
        }
    }

    fn runBatch(self: *const Self, props: *const cli.SetCpuProps, gpu: *?Gpu) usize {
        var err_hit: usize = 0;

        if (props.op_mode) |mode| self.cpu.setPstateOpMode(mode) catch |err| {
            std.log.err("failed to set P-state operation mode: {s}", .{@errorName(err)});
            err_hit += 1;
        };
        if (props.scaling_governor) |gov| self.cpu.setScalingGovernor(gov) catch |err| {
            std.log.err("failed to set scaling governor: {s}", .{@errorName(err)});
            err_hit += 1;
        };
        if (props.energy_perf_policy) |policy| self.cpu.setEnergyPerformancePolicy(policy) catch |err| {
            std.log.err("failed to set energy performance policy: {s}", .{@errorName(err)});
            err_hit += 1;
        };
        if (props.turbo_boost) |tb| self.cpu.setTurboBoost(tb) catch |err| {
            std.log.err("failed to set turbo boost: {s}", .{@errorName(err)});
            err_hit += 1;
        };
        if (props.hwp_dyn_boost) |hwp| self.cpu.setIntelDynBoost(hwp) catch |err| {
            std.log.err("failed to set Intel HWP dynamic boost: {s}", .{@errorName(err)});
            err_hit += 1;
        };
        if (props.xe_power_profile) |xe| gpu.*.?.setXePowerProfile(xe.profile, xe.gpu_index) catch |err| {
            std.log.err("failed to set Intel Xe power profile: {s}", .{@errorName(err)});
            err_hit += 1;
        };

        return err_hit;
    }

    fn needGpuLookup(parsed: *const cli.Parsed, config: *const UserConfig) bool {
        return switch (parsed.*) {
            .info => |component| switch (component) {
                .gpu => true,
                else => false,
            },
            .get => |props| {
                return if (props.xe_power_profile) |_| true else false;
            },
            .set => |props| {
                return if (props.xe_power_profile) |_| true else false;
            },
            .set_profile => |d| {
                const profile = switch (d.profile) {
                    .performance => config.performance,
                    .balance => config.balance,
                    .save => config.save,
                } orelse return false;
                return if (@field(profile, "xe_power_profile")) |_| true else false;
            },
            .daemon => {
                if (config.performance.xe_power_profile) |_| return true;
                if (config.balance.xe_power_profile) |_| return true;
                if (config.save) |save| if (save.xe_power_profile) |_| return true;
                return false;
            },
            else => false,
        };
    }

    pub fn deinit(self: *Self) void {
        self.cpu.deinit();
    }
};

fn hasRoot() !void {
    if (std.os.linux.geteuid() != 0) {
        std.log.err("root privileges missing", .{});
        return error.RootRequired;
    }
}
