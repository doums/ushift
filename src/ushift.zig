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
    gpu: Gpu,

    var _gpa: std.mem.Allocator = undefined;
    var _io: std.Io = undefined;

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !Self {
        _gpa = gpa;
        _io = io;
        var cpu = try Cpu.init(gpa, io);
        errdefer cpu.deinit();
        const gpu = try Gpu.init(gpa, io);

        return Self{
            .cpu = cpu,
            .gpu = gpu,
        };
    }

    pub fn dispatch(self: *const Self, parsed: cli.Parsed, config: *const UserConfig) !void {
        var err_hit: usize = 0;
        switch (parsed) {
            .get => |props| {
                if (props.driver) |_| self.cpu.printDriver() catch {};
                if (props.op_mode) |_| self.cpu.printPstateOpMode() catch {};
                if (props.scaling_governor) |_| self.cpu.printScalingGovernor() catch {};
                if (props.energy_perf_policy) |_| self.cpu.printEnergyPerformancePolicy() catch {};
                if (props.turbo_boost) |_| self.cpu.printTurboBoost() catch {};
                if (props.hwp_dyn_boost) |_| self.cpu.printIntelDynBoost() catch {};
                if (props.intel_xe_power_profile) |p|
                    self.gpu.driverAction(.xe, .print, p.gpu_index) catch {};
                if (props.radeon_dpm_perf_level) |p|
                    self.gpu.driverAction(.amd, .print, p.gpu_index) catch {};
            },
            .set => |props| {
                try hasRoot();
                err_hit = self.runBatch(&props);
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
                self.gpu.setProfile(&profile) catch {
                    err_hit += 1;
                };
            },
            .info => |kind| switch (kind) {
                .cpu => self.cpu.print(),
                .gpu => self.gpu.print(),
            },
            .power_supply => pws.printPowerSupply(_gpa, _io) catch {
                // TODO handle absence of battery or AC gracefully
                // ie. on desktop
            },
            .daemon => |flags| {
                if (!flags.dry_run) try hasRoot();
                var d = try Daemon.init(_gpa, _io, .{
                    .cpu = &self.cpu,
                    .gpu = &self.gpu,
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

    fn runBatch(self: *const Self, props: *const cli.SetCpuProps) usize {
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
        if (props.intel_xe_power_profile) |p|
            self.gpu.driverAction(
                .xe,
                .{ .set = .{ .xe = p.profile } },
                p.gpu_index,
            ) catch |err| {
                std.log.err("failed to set Intel Xe power profile: {s}", .{@errorName(err)});
                err_hit += 1;
            };
        if (props.radeon_dpm_perf_level) |p|
            self.gpu.driverAction(
                .amd,
                .{ .set = .{ .amd = p.level } },
                p.gpu_index,
            ) catch |err| {
                std.log.err("failed to set AMD Radeon DPM performance level: {s}", .{@errorName(err)});
                err_hit += 1;
            };

        return err_hit;
    }

    pub fn deinit(self: *Self) void {
        self.cpu.deinit();
        self.gpu.deinit();
    }
};

fn hasRoot() !void {
    if (std.os.linux.geteuid() != 0) {
        std.log.err("root privileges missing", .{});
        return error.RootRequired;
    }
}
