// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Pierre Dommerc

const std = @import("std");
const fs = @import("fs.zig");
const ProcInfo = @import("procinfo.zig").ProcInfo;
const Profile = @import("cli.zig").Profile;

const cpu_dir = "/sys/devices/system/cpu";
const intel_pstate_dir = "/sys/devices/system/cpu/intel_pstate";
const amd_pstate_dir = "/sys/devices/system/cpu/amd_pstate";
const cpu_freq_dir = "/sys/devices/system/cpu/cpufreq";
const intel_turbo_boost = intel_pstate_dir ++ "/no_turbo";
const intel_dyn_boost = intel_pstate_dir ++ "/hwp_dynamic_boost";
const generic_boost = cpu_freq_dir ++ "/boost";

pub const GenericPstateOpMode = enum {
    active,
    passive,
    guided,
    off,

    fn vendored(self: GenericPstateOpMode, vendor: Vendor) ?PstateOpMode {
        return switch (vendor) {
            .intel => switch (self) {
                .active => .{ .intel = .active },
                .passive => .{ .intel = .passive },
                .off => .{ .intel = .off },
                else => null,
            },
            .amd => switch (self) {
                .active => .{ .amd = .active },
                .passive => .{ .amd = .passive },
                .guided => .{ .amd = .guided },
                .off => .{ .amd = .disable },
            },
            else => null,
        };
    }
};

// https://docs.kernel.org/admin-guide/pm/intel_pstate.html#global-attributes `status`
const IntelPstateOpMode = enum { active, passive, off };
// https://www.kernel.org/doc/html/latest/admin-guide/pm/amd-pstate.html#global-attributes `status`
const AmdPstateOpMode = enum { active, passive, guided, disable };

pub const PstateOpMode = union(enum) {
    intel: IntelPstateOpMode,
    amd: AmdPstateOpMode,

    fn isActive(self: PstateOpMode) bool {
        return switch (self) {
            .intel => |s| s == .active,
            .amd => |s| s == .active,
        };
    }

    fn isPassive(self: PstateOpMode) bool {
        return switch (self) {
            .intel => |s| s == .passive,
            .amd => |s| s == .passive,
        };
    }

    fn getName(self: PstateOpMode) []const u8 {
        return switch (self) {
            .intel => |s| @tagName(s),
            .amd => |s| @tagName(s),
        };
    }
};

pub const Driver = union(enum) {
    intel_pstate,
    intel_pstate_passive, // no HWP
    amd_pstate,
    amd_pstate_epp,
    other: []u8,

    fn getName(self: *const Driver) []const u8 {
        return switch (self.*) {
            .other => |d| d,
            else => @tagName(self.*),
        };
    }
};

pub const Vendor = enum {
    intel,
    amd,
    unknown,

    fn fromDriver(driver: *const Driver) Vendor {
        return switch (driver.*) {
            .intel_pstate, .intel_pstate_passive => .intel,
            .amd_pstate, .amd_pstate_epp => .amd,
            .other => |d| {
                if (std.mem.find(u8, d, "intel") != null) {
                    return .intel;
                } else if (std.mem.find(u8, d, "amd") != null) {
                    return .amd;
                } else {
                    return .unknown;
                }
            },
        };
    }

    fn getName(self: Vendor) []const u8 {
        return switch (self) {
            .intel => "Intel",
            .amd => "AMD",
            .unknown => "Unknown",
        };
    }
};

pub const ScalingGovernor = enum {
    // intel_pstate and amd_pstate in active mode
    performance,
    powersave,
    // other drivers
    userspace,
    ondemand,
    conservative,
    schedutil,
};

// Generic energy performance policy, which we will translate to the appropriate driver-specific setting
// https://docs.kernel.org/admin-guide/pm/intel_pstate.html#energy-vs-performance-hints
pub const EnergyPerfPolicy = enum {
    performance,
    balance_performance,
    default, // for Intel EPP: kernel translates default into balance_performance
    balance_power,
    power,
};

// https://docs.kernel.org/admin-guide/pm/intel_epb.html
pub const IntelEnergyBiasHint = enum {
    performance,
    balance_performance,
    normal,
    balance_power,
    power,

    pub fn fromPolicy(policy: EnergyPerfPolicy) IntelEnergyBiasHint {
        return switch (policy) {
            .performance => .performance,
            .balance_performance => .balance_performance,
            .default => .normal,
            .balance_power => .balance_power,
            .power => .power,
        };
    }

    pub fn toSysfsStr(self: IntelEnergyBiasHint) []const u8 {
        return switch (self) {
            .balance_performance => "balance-performance",
            .balance_power => "balance-power",
            else => @tagName(self),
        };
    }
};

pub const Cpu = struct {
    vendor: Vendor,
    driver: Driver,
    procinfo: ProcInfo,
    pstate_op_mode: ?PstateOpMode,

    var _gpa: std.mem.Allocator = undefined;
    var _io: std.Io = undefined;

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !Self {
        _gpa = gpa;
        _io = io;

        const driver = try getActiveDriver(gpa, io);
        errdefer if (driver == .other)
            _gpa.free(driver.other);

        const vendor = Vendor.fromDriver(&driver);
        const pstate_status = switch (vendor) {
            .intel => try getPstateOpMode(.intel, io),
            .amd => try getPstateOpMode(.amd, io),
            else => null,
        };
        const procinfo = try ProcInfo.parse(gpa, io, vendor);

        return Cpu{
            .vendor = vendor,
            .driver = driver,
            .procinfo = procinfo,
            .pstate_op_mode = pstate_status,
        };
    }

    pub fn print(self: *const Self) void {
        self.procinfo.print();
        std.debug.print(
            \\Vendor: {s}
            \\Scaling driver: {s}
            \\P-state mode: {s}
            \\
        , .{
            @tagName(self.vendor),
            self.driver.getName(),
            if (self.pstate_op_mode) |s| s.getName() else "N/A",
        });
        if (self.vendor == .intel) {
            std.debug.print(
                \\HWP EPP: {s}
                \\EPB: {s}
                \\
            , .{
                if (self.procinfo.intel_epp) "yes" else "no",
                if (self.procinfo.intel_epb) "yes" else "no",
            });
        }
    }

    /// Print the driver
    pub fn printDriver(self: *const Self) !void {
        std.debug.print("Scaling driver: {s}\n", .{self.driver.getName()});
    }

    /// Print the current P-state driver operation mode
    pub fn printPstateOpMode(self: *const Self) !void {
        const mode = if (self.pstate_op_mode) |s| s.getName() else "N/A";
        std.debug.print("P-state mode: {s}\n", .{mode});
    }

    /// Set the P-state driver operation mode
    pub fn setPstateOpMode(self: *const Self, mode: GenericPstateOpMode) !void {
        if (self.driver == .other) {
            return error.UnsupportedDriver;
        }
        const op_mode = mode.vendored(self.vendor) orelse return error.UnsupportedPstateOpMode;
        const path = switch (self.vendor) {
            .intel => intel_pstate_dir ++ "/status",
            .amd => amd_pstate_dir ++ "/status",
            else => unreachable,
        };
        std.debug.print("setting {s} to {s}\n", .{ path, op_mode.getName() });
        try fs.writeFile(_io, path, op_mode.getName());
    }

    /// Print the current CPU scaling governor
    pub fn printScalingGovernor(_: *const Self) !void {
        const path = cpu_dir ++ "/cpu0/cpufreq/scaling_governor";
        var buf: [256]u8 = undefined;
        const governor = fs.readLine(256, _io, path, &buf, .{ .trim = true }) catch |err| {
            std.log.err("failed to read scaling governor: {s}", .{@errorName(err)});
            return err;
        } orelse return error.SysfsReadEmpty;
        std.debug.print("Scaling governor: {s}\n", .{governor});
    }

    /// Set the CPU scaling governor
    /// intel_pstate, amd_pstate in active mode: powersave, performance
    /// other drivers: performance, powersave, userspace, ondemand, conservative, schedutil
    pub fn setScalingGovernor(self: *const Self, governor: ScalingGovernor) !void {
        if (governor != .performance and governor != .powersave and self.isPstateActive()) {
            std.log.err("governor {s} is not supported in P-state active mode", .{@tagName(governor)});
            return error.UnsupportedGovernor;
        }
        std.debug.print("setting scaling governor to '{s}'\n", .{@tagName(governor)});
        try writeSysfsCpus("/cpufreq/scaling_governor", _io, @tagName(governor));
    }

    /// Print the current energy performance policy
    pub fn printEnergyPerformancePolicy(self: *const Self) !void {
        const intel_epp = self.vendor == .intel and self.isPstateActive() and self.procinfo.intel_epp;
        const amd_epp = self.vendor == .amd and self.isPstateActive();

        const path = if (intel_epp or amd_epp)
            cpu_dir ++ "/cpu0/cpufreq/energy_performance_preference"
        else if (self.vendor == .intel and self.procinfo.intel_epb)
            cpu_dir ++ "/cpu0/power/energy_perf_bias"
        else {
            std.debug.print("Energy performance policy: not supported on this CPU\n", .{});
            return;
        };

        var buf: [256]u8 = undefined;
        const epp = fs.readLine(256, _io, path, &buf, .{ .trim = true }) catch |err| {
            std.log.err("failed to read energy performance policy: {s}", .{@errorName(err)});
            return err;
        } orelse return error.SysfsReadEmpty;
        std.debug.print("Energy performance policy: {s}\n", .{epp});
    }

    pub fn setEnergyPerformancePolicy(self: *const Self, policy: EnergyPerfPolicy) !void {
        // https://docs.kernel.org/admin-guide/pm/intel_pstate.html#hwp-performance
        if (self.vendor == .intel and self.isPstateActive()) {
            const governor = try getScalingGovernor(_io);
            if (governor == .performance) {
                std.log.err("energy performance policy is not supported with performance governor", .{});
                return error.UnsupportedScalingGovernor;
            }
        }

        const intel_epp = self.vendor == .intel and self.isPstateActive() and self.procinfo.intel_epp;
        const amd_epp = self.vendor == .amd and self.isPstateActive();

        if (intel_epp or amd_epp) {
            std.debug.print("setting EPP to '{s}'\n", .{@tagName(policy)});
            try writeSysfsCpus(
                "/cpufreq/energy_performance_preference",
                _io,
                @tagName(policy),
            );
        } else if (self.vendor == .intel and self.procinfo.intel_epb) {
            std.debug.print("setting EPB to '{s}'\n", .{@tagName(policy)});
            try writeSysfsCpus(
                "/power/energy_perf_bias",
                _io,
                IntelEnergyBiasHint.fromPolicy(policy).toSysfsStr(),
            );
        } else {
            std.log.err("energy performance policy is not supported on this CPU", .{});
            return error.UnsupportedCpu;
        }
    }

    /// Print turbo boost status
    pub fn printTurboBoost(self: *const Self) !void {
        const path = switch (self.driver) {
            .intel_pstate, .intel_pstate_passive => intel_turbo_boost,
            else => generic_boost,
        };

        var buf: [32]u8 = undefined;
        const boost = fs.readLine(32, _io, path, &buf, .{ .trim = true }) catch |err| {
            std.log.err("failed to read turbo boost status: {s}", .{@errorName(err)});
            return err;
        } orelse return error.SysfsReadEmpty;

        const status = switch (self.driver) {
            .intel_pstate,
            .intel_pstate_passive,
            => if (std.mem.eql(u8, boost, "1")) "OFF" else "ON",
            else => if (std.mem.eql(u8, boost, "1")) "ON" else "OFF",
        };
        std.debug.print("Turbo boost: {s}\n", .{status});
    }

    /// Set "turbo boost" (Intel) or "turbo core" (AMD)
    pub fn setTurboBoost(self: *const Self, enabled: bool) !void {
        switch (self.driver) {
            .intel_pstate, .intel_pstate_passive => {
                // https://wiki.archlinux.org/title/CPU_frequency_scaling#Setting_via_sysfs_(intel_pstate)
                std.debug.print("{s} turbo boost ({s})\n", .{
                    if (enabled) "enabling" else "disabling",
                    intel_turbo_boost,
                });
                try fs.writeFile(_io, intel_turbo_boost, if (enabled) "0" else "1");
            },
            else => {
                // https://wiki.archlinux.org/title/CPU_frequency_scaling#Setting_via_sysfs_(other_scaling_drivers)
                std.debug.print("{s} turbo boost ({s})\n", .{
                    if (enabled) "enabling" else "disabling",
                    generic_boost,
                });
                try fs.writeFile(_io, generic_boost, if (enabled) "1" else "0");
            },
        }
    }

    /// Print the current Intel HWP dynamic boost status
    pub fn printIntelDynBoost(self: *const Self) !void {
        if (self.vendor != .intel) {
            std.debug.print("HWP dynamic boost is only supported on Intel cpus\n", .{});
            return error.UnsupportedCpu;
        }
        if (self.driver != .intel_pstate) {
            std.debug.print("HWP dynamic boost is only supported on intel_pstate driver in active mode\n", .{});
            return error.UnsupportedDriver;
        }

        var buf: [32]u8 = undefined;
        const boost = fs.readLine(32, _io, intel_dyn_boost, &buf, .{ .trim = true }) catch |err| {
            std.log.err("failed to read HWP dynamic boost: {s}", .{@errorName(err)});
            return err;
        } orelse return error.SysfsReadEmpty;

        const status = if (std.mem.eql(u8, boost, "1")) "ON" else "OFF";
        std.debug.print("HWP dynamic boost: {s}\n", .{status});
    }

    /// Set Intel HWP dynamic boost
    pub fn setIntelDynBoost(self: *const Self, enabled: bool) !void {
        if (self.vendor != .intel) {
            std.log.err("HWP dynamic boost is only supported on Intel cpus", .{});
            return error.UnsupportedCpu;
        }
        if (self.driver != .intel_pstate or !self.isPstateActive()) {
            std.log.err("HWP dynamic boost is only supported on intel_pstate driver in active mode", .{});
            return error.UnsupportedDriver;
        }
        std.debug.print("{s} HWP dynamic boost ({s})\n", .{
            if (enabled) "enabling" else "disabling",
            intel_dyn_boost,
        });
        try fs.writeFile(_io, intel_dyn_boost, if (enabled) "1" else "0");
    }

    pub fn setProfile(self: *const Self, profile: *const Profile) !void {
        std.log.debug("set profile: {any}", .{profile});
        var err_hit: bool = false;
        if (profile.pstate_op_mode) |mode| {
            self.setPstateOpMode(mode) catch |err| {
                std.log.err("failed to set P-state operation mode: {s}", .{@errorName(err)});
                err_hit = true;
            };
        }
        if (profile.governor) |gov| {
            self.setScalingGovernor(gov) catch |err| {
                std.log.err("failed to set scaling governor: {s}", .{@errorName(err)});
                err_hit = true;
            };
        }
        if (profile.energy_perf_policy) |policy| {
            self.setEnergyPerformancePolicy(policy) catch |err| {
                std.log.err("failed to set energy performance policy: {s}", .{@errorName(err)});
                err_hit = true;
            };
        }
        if (profile.turbo_boost) |b| {
            self.setTurboBoost(b) catch |err| {
                std.log.err("failed to set turbo boost: {s}", .{@errorName(err)});
                err_hit = true;
            };
        }
        if (profile.hwp_dyn_boost) |b| {
            self.setIntelDynBoost(b) catch |err| {
                std.log.err("failed to set Intel HWP dynamic boost: {s}", .{@errorName(err)});
                err_hit = true;
            };
        }
        if (err_hit) {
            return error.ApplyProfileFailed;
        }
    }

    /// Check if the P-state driver is in active mode
    fn isPstateActive(self: *const Self) bool {
        switch (self.driver) {
            .intel_pstate, .amd_pstate, .amd_pstate_epp => {},
            else => return false,
        }
        return if (self.pstate_op_mode) |mode| mode.isActive() else false;
    }

    pub fn deinit(self: *Self) void {
        if (self.driver == .other) {
            _gpa.free(self.driver.other);
        }
        self.procinfo.deinit(_gpa);
    }
};

// caller owns driver name memory if 'other'
fn getActiveDriver(gpa: std.mem.Allocator, io: std.Io) !Driver {
    // https://wiki.archlinux.org/title/CPU_frequency_scaling#Scaling_drivers
    const SysfsDriver = enum {
        intel_pstate,
        intel_cpufreq,
        amd_pstate,
        @"amd-pstate",
        amd_pstate_epp,
        @"amd-pstate-epp",
        other,
    };
    var buf: [256]u8 = undefined;
    const sysfs_drv = try fs.readLine(
        256,
        io,
        cpu_dir ++ "/cpu0/cpufreq/scaling_driver",
        &buf,
        .{},
    ) orelse return error.SysfsReadEmpty;
    std.log.debug("CPU driver {s}", .{sysfs_drv});
    const drv = std.meta.stringToEnum(SysfsDriver, sysfs_drv) orelse .other;

    const driver: Driver = switch (drv) {
        .intel_pstate => .intel_pstate,
        .intel_cpufreq => .intel_pstate_passive,
        .amd_pstate, .@"amd-pstate" => .amd_pstate,
        .amd_pstate_epp, .@"amd-pstate-epp" => .amd_pstate_epp,
        else => .{ .other = try gpa.dupe(u8, sysfs_drv) },
    };

    return driver;
}

const PstateVendor = enum {
    intel,
    amd,
};

fn checkPstateDir(comptime vendor: PstateVendor, io: std.Io) !bool {
    const pstate_dir = cpu_dir ++ "/" ++ @tagName(vendor) ++ "_pstate";
    return try fs.dirExists(io, pstate_dir);
}

fn getPstateOpMode(comptime vendor: PstateVendor, io: std.Io) !?PstateOpMode {
    const dir_exists = try checkPstateDir(vendor, io);
    if (!dir_exists) {
        return null;
    }
    const path = switch (vendor) {
        .intel => intel_pstate_dir ++ "/status",
        .amd => amd_pstate_dir ++ "/status",
    };
    var buf: [256]u8 = undefined;
    const status = try fs.readLine(
        256,
        io,
        path,
        &buf,
        .{},
    ) orelse return error.SysfsReadEmpty;
    const pstatus = std.meta.stringToEnum(if (vendor == .intel) IntelPstateOpMode else AmdPstateOpMode, status) orelse {
        std.log.err("unknown {s}_pstate status: {s}", .{ @tagName(vendor), status });
        return null;
    };
    return @unionInit(PstateOpMode, @tagName(vendor), pstatus);
}

fn getScalingGovernor(io: std.Io) !ScalingGovernor {
    const path = cpu_dir ++ "/cpu0/cpufreq/scaling_governor";
    var buf: [256]u8 = undefined;
    const gov_str = try fs.readLine(
        256,
        io,
        path,
        &buf,
        .{ .trim = true },
    ) orelse return error.SysfsReadEmpty;
    return std.meta.stringToEnum(ScalingGovernor, gov_str) orelse {
        std.log.err("unknown scaling governor: {s}", .{gov_str});
        return error.UnknownScalingGovernor;
    };
}

fn writeSysfsCpus(
    comptime subpath: []const u8,
    io: std.Io,
    data: []const u8,
) !void {
    // 1024 cpu cores should be safe for the foreseable future
    var items_buf: [1024]u32 = undefined;
    const cpus = try fs.collectDirItems(1024, io, &items_buf, .{
        .file_kind = .directory,
        .path = cpu_dir,
        .prefix = "cpu",
    });

    var path_buf: [512]u8 = undefined;
    for (cpus) |num| {
        const path = try std.fmt.bufPrint(&path_buf, "{s}/cpu{d}{s}", .{ cpu_dir, num, subpath });
        std.log.debug("writing '{s}' to {s}", .{ data, path });
        try fs.writeFile(io, path, data);
    }
}

const testing = std.testing;
test "cpu" {
    var cpu = try Cpu.init(testing.allocator, testing.io);
    defer cpu.deinit();
    std.debug.print("{any}\n", .{cpu});
    cpu.print();
    // cpu.setPstateOpMode(.active) catch |err| {
    //     std.log.err("failed to set P-state operation mode: {s}", .{@errorName(err)});
    // };
}

test "set_pstate_opmode" {
    var cpu = try Cpu.init(testing.allocator, testing.io);
    defer cpu.deinit();
    try cpu.setPstateOpMode(.active);
}

test "set_scaling_governor" {
    var cpu = try Cpu.init(testing.allocator, testing.io);
    defer cpu.deinit();
    try cpu.setScalingGovernor(.powersave);
}

test "get_scaling_governor" {
    const gov = try getScalingGovernor(testing.io);
    std.debug.print("current scaling governor: {s}\n", .{@tagName(gov)});
}

test "set_boost" {
    var cpu = try Cpu.init(testing.allocator, testing.io);
    defer cpu.deinit();
    try cpu.setTurboBoost(true);
}

test "set_dyn_boost" {
    var cpu = try Cpu.init(testing.allocator, testing.io);
    defer cpu.deinit();
    try cpu.setIntelDynBoost(true);
}
