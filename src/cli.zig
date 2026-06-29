// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Pierre Dommerc

const std = @import("std");
const clap = @import("clap");

const bin_name = @import("buildmeta").name;
const bin_version = @import("buildmeta").version;

const cpu = @import("cpu.zig");
const gpu = @import("gpu.zig");
const log = @import("log.zig");

pub const Command = enum {
    cpu,
    gpu,
    get,
    set,
    perf,
    performance,
    bal,
    balance,
    sav,
    save,
    cfg,
    laptop,
    pows,
};

pub const GetCpuProps = struct {
    driver: ?bool = null,
    op_mode: ?bool = null,
    scaling_governor: ?bool = null,
    energy_perf_policy: ?bool = null,
    turbo_boost: ?bool = null,
    hwp_dyn_boost: ?bool = null,
    xe_power_profile: ?struct {
        gpu_index: u32 = 0,
    } = null,
};

pub const SetCpuProps = struct {
    op_mode: ?cpu.GenericPstateOpMode = null,
    scaling_governor: ?cpu.ScalingGovernor = null,
    energy_perf_policy: ?cpu.EnergyPerfPolicy = null,
    turbo_boost: ?bool = null,
    hwp_dyn_boost: ?bool = null,
    xe_power_profile: ?struct {
        profile: gpu.XePowerProfile = .base,
        gpu_index: u32 = 0,
    } = null,
};

pub const DaemonProps = struct {
    config_file: ?[]const u8 = null,
    bat_name: ?[]const u8 = null,
    low_level: ?u8 = null,
    poll_rate: ?u32 = null,
    gpu_index: ?u32 = null,
};

pub const Parsed = union(enum) {
    info: enum { cpu, gpu },
    power_supply,
    get: GetCpuProps,
    set: SetCpuProps,
    set_profile: struct {
        profile: CpuProfile,
        config_file: ?[]const u8,
    },
    showcfg: struct { file: ?[]const u8 },
    daemon: DaemonProps,
    noop,
};

pub const CpuProfile = enum {
    performance,
    balance,
    save,
};

pub const Profile = struct {
    governor: ?cpu.ScalingGovernor,
    pstate_op_mode: ?cpu.GenericPstateOpMode,
    energy_perf_policy: ?cpu.EnergyPerfPolicy,
    xe_power_profile: ?gpu.XePowerProfile, // Intel only
    turbo_boost: ?bool,
    hwp_dyn_boost: ?bool, // Intel only

    pub fn default(comptime profile: CpuProfile) Profile {
        return Profile{
            .governor = null,
            .pstate_op_mode = null,
            .energy_perf_policy = switch (profile) {
                .performance => .balance_performance,
                .balance => .balance_power,
                .save => .power,
            },
            .xe_power_profile = null,
            .turbo_boost = switch (profile) {
                .save => false,
                else => true,
            },
            .hwp_dyn_boost = null,
        };
    }
};

const main_parsers = .{
    .command = clap.parsers.enumeration(Command),
};

const main_params = clap.parseParamsComptime(
    \\-h, --help           Print help
    \\-v, --version        Print version
    \\<command>
    \\
);

const main_help =
    \\CLI tool to manage CPU performance scaling and power profiles
    \\
    \\Usage: ushift [OPTIONS] [COMMAND]
    \\
    \\Commands:
    \\  get       Get cpu settings
    \\  set       Set cpu settings (root required)
    \\  perf, performance
    \\            Apply the 'performance' profile (root required)
    \\  bal, balance
    \\            Apply the 'balance' profile (root required)
    \\  sav, save
    \\            Apply the 'save' profile (root required)
    \\  cpu       Print cpu info
    \\  gpu       Print gpu info
    \\  pows      Print power supply info (battery/AC)
    \\  cfg       Print config file
    \\  laptop    Run ushift in laptop mode (root required)
    \\
    \\Options:
    \\  -h, --help      Print help
    \\  -v, --version   Print version
    \\
;

const MainArgs = clap.ResultEx(clap.Help, &main_params, main_parsers);

pub fn cli(args: std.process.Args, io: std.Io, gpa: std.mem.Allocator) !Parsed {
    var iter = try args.iterateAllocator(gpa);
    defer iter.deinit();

    // skip program name
    _ = iter.next();

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &main_params, main_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
        .terminating_positional = 0,
    }) catch |err| {
        report(diag, err);
        try printUsage(io, &main_params, null);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print(main_help, .{});
        return .noop;
    }
    if (res.args.version != 0) {
        std.debug.print("{s} {s}\n", .{ bin_name, bin_version });
        return .noop;
    }

    const command = res.positionals[0] orelse {
        std.debug.print(main_help, .{});
        return .noop;
    };
    return switch (command) {
        .perf, .performance => try setProfile(.performance, io, gpa, &iter),
        .bal, .balance => try setProfile(.balance, io, gpa, &iter),
        .sav, .save => try setProfile(.save, io, gpa, &iter),
        .get => try get(io, gpa, &iter),
        .set => try set(io, gpa, &iter),
        .cfg => try showConfig(io, gpa, &iter),
        .cpu => try info(.cpu, io, gpa, &iter),
        .gpu => try info(.gpu, io, gpa, &iter),
        .pows => try powerSupply(io, gpa, &iter),
        .laptop => try laptop(io, gpa, &iter),
    };
}

fn setProfile(
    comptime profile: CpuProfile,
    io: std.Io,
    gpa: std.mem.Allocator,
    iter: *std.process.Args.Iterator,
) !Parsed {
    var help_buf: [256]u8 = undefined;
    const profile_str = @tagName(profile);
    const help = try std.fmt.bufPrint(&help_buf,
        \\Set CPU '{s}' profile as defined in the config file (requires root)
        \\
        \\Usage: ushift [OPTIONS] {s}
        \\
        \\Options:
        \\
    , .{ profile_str, profile_str });

    const options =
        \\  -c, --config <FILE>   Path to config file (default: /etc/ushift/config.toml)
        \\  -h, --help            Print help
        \\
    ;

    const params = comptime clap.parseParamsComptime(options);
    const parsers = comptime .{
        .FILE = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        report(diag, err);
        try printUsage(io, &params, profile_str);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("{s}{s}\n", .{ help, options });
        return .noop;
    }
    return .{ .set_profile = .{
        .profile = profile,
        .config_file = res.args.config,
    } };
}

const YesNo = enum {
    yes,
    no,

    fn asBool(y: YesNo) bool {
        switch (y) {
            .yes => return true,
            .no => return false,
        }
    }
};

fn get(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !Parsed {
    const help =
        \\Get CPU scaling properties
        \\
        \\Usage: ushift get [OPTIONS]
        \\
        \\Options:
        \\  -D, --driver        Print the scaling driver
        \\  -o, --op-mode       Print the P-state driver operation mode
        \\  -g, --scaling-governor
        \\        Print the scaling governor
        \\  -e, --energy-perf-policy
        \\        Print the energy performance policy
        \\  -t, --turbo         Print turbo boost status
        \\  -d, --dyn-boost     Print Intel HWP dynamic boost status
        \\  -x, --xe-power-profile
        \\        Print the Xe (i)GPU power profile (Intel xe driver only)
        \\  -G, --gpu-index <INDEX>
        \\        Set the GPU index for the --xe-power-profile option (default: 0)
        \\  -h, --help          Print help
        \\
    ;

    const options =
        \\  -D, --driver
        \\  -o, --op-mode
        \\  -g, --scaling-governor
        \\  -e, --energy-perf-policy
        \\  -t, --turbo
        \\  -d, --dyn-boost
        \\  -x, --xe-power-profile
        \\  -G, --gpu-index <GPU_INDEX>
        \\  -h, --help
        \\
    ;

    const params = comptime clap.parseParamsComptime(options);
    const parsers = comptime .{
        .GPU_INDEX = clap.parsers.int(u32, 10),
    };
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        report(diag, err);
        try printUsage(io, &params, "get");
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("{s}\n", .{help});
        return .noop;
    }

    var props: GetCpuProps = .{};
    if (res.args.driver != 0) {
        props.driver = true;
    }
    if (res.args.@"op-mode" != 0) {
        props.op_mode = true;
    }
    if (res.args.@"scaling-governor" != 0) {
        props.scaling_governor = true;
    }
    if (res.args.@"energy-perf-policy" != 0) {
        props.energy_perf_policy = true;
    }
    if (res.args.turbo != 0) {
        props.turbo_boost = true;
    }
    if (res.args.@"dyn-boost" != 0) {
        props.hwp_dyn_boost = true;
    }
    if (res.args.@"xe-power-profile" != 0) {
        props.xe_power_profile = .{
            .gpu_index = res.args.@"gpu-index" orelse 0,
        };
    }
    return .{ .get = props };
}

fn set(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !Parsed {
    const help =
        \\Set CPU scaling properties (requires root)
        \\
        \\Usage: ushift set [OPTIONS]
        \\
        \\Options:
        \\  -o, --op-mode <OPMODE>
        \\        Set the P-state driver operation mode, possible values:
        \\        intel_pstate: active, passive, off
        \\        amd_pstate: active, passive, guided, off
        \\  -g, --scaling-governor <GOVERNOR>
        \\        Set the scaling governor, possible values:
        \\        intel_pstate and amd_pstate: powersave, performance
        \\        other drivers: performance, powersave, userspace, ondemand, conservative, schedutil
        \\  -e, --energy-perf-policy <EPP>
        \\        Set the energy performance policy, possible values:
        \\        performance, balance_performance, default, balance_power, power
        \\        Note: not supported if intel_pstate in active mode with 'performance' governor
        \\  -t, --turbo <yes|no>        Set turbo boost
        \\  -d, --dyn-boost <yes|no>    Set Intel HWP dynamic boost
        \\  -x, --xe-power-profile <PROFILE>
        \\        Set the Xe (i)GPU power profile (Intel xe driver only), possible values:
        \\        base, power_saving
        \\  -G, --gpu-index <INDEX>
        \\        Set the GPU index for the --xe-power-profile option (default: 0)
        \\  -h, --help          Print help
        \\
    ;

    const options =
        \\  -o, --op-mode <OPMODE>
        \\  -g, --scaling-governor <GOVERNOR>
        \\  -e, --energy-perf-policy <EPP>
        \\  -t, --turbo <BOOST>
        \\  -d, --dyn-boost <DYNBOOST>
        \\  -x, --xe-power-profile <XE_PROFILE>
        \\  -G, --gpu-index <GPU_INDEX>
        \\  -h, --help
        \\
    ;

    const params = comptime clap.parseParamsComptime(options);
    const parsers = comptime .{
        .OPMODE = clap.parsers.enumeration(cpu.GenericPstateOpMode),
        .GOVERNOR = clap.parsers.enumeration(cpu.ScalingGovernor),
        .EPP = clap.parsers.enumeration(cpu.EnergyPerfPolicy),
        .BOOST = clap.parsers.enumeration(YesNo),
        .DYNBOOST = clap.parsers.enumeration(YesNo),
        .XE_PROFILE = clap.parsers.enumeration(gpu.XePowerProfile),
        .GPU_INDEX = clap.parsers.int(u32, 10),
    };
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        report(diag, err);
        try printUsage(io, &params, "set");
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("{s}\n", .{help});
        return .noop;
    }

    var props: SetCpuProps = .{};
    if (res.args.@"op-mode") |mode| {
        props.op_mode = mode;
    }
    if (res.args.@"scaling-governor") |governor| {
        props.scaling_governor = governor;
    }
    if (res.args.@"energy-perf-policy") |epp| {
        props.energy_perf_policy = epp;
    }
    if (res.args.turbo) |boost| {
        props.turbo_boost = boost.asBool();
    }
    if (res.args.@"dyn-boost") |boost| {
        props.hwp_dyn_boost = boost.asBool();
    }
    if (res.args.@"xe-power-profile") |profile| {
        props.xe_power_profile = .{
            .profile = profile,
            .gpu_index = res.args.@"gpu-index" orelse 0,
        };
    }
    return .{ .set = props };
}

fn laptop(
    io: std.Io,
    gpa: std.mem.Allocator,
    iter: *std.process.Args.Iterator,
) !Parsed {
    const help =
        \\Run ushift in "laptop mode" as a daemon (root required)
        \\
        \\In this mode ushift monitors power state and automatically
        \\switches profiles:
        \\ - 'performance' -> on AC power
        \\ - 'balance'     -> on battery
        \\ - 'save'        -> on battery below `low_level` %
        \\   (only if [save] is defined in config)
        \\
        \\Usage: ushift laptop [OPTIONS]
        \\
        \\Options:
        \\
    ;

    const options =
        \\  -b, --bat-name <BATNAME>
        \\              Set the battery device name to use,
        \\              e.g. "BAT0" for /sys/class/power_supply/BAT0
        \\              (only needed if multiple batteries are present)
        \\  -l, --low-level <BAT_LEVEL>
        \\              Set the battery percentage below which the 'save' profile
        \\              is applied
        \\              Expected values: 0-100 (%) (default: 20)
        \\  -r, --poll-rate <POLLRATE>
        \\              Set the battery polling interval in seconds (default: 30)
        \\  -g, --gpu-index <GPU_INDEX>
        \\              Set the GPU index for the --xe-power-profile option
        \\  -L, --log-level <LOG_LEVEL>
        \\              Set the log level, possible values: debug, info, warn, err
        \\  -c, --config <FILE>   Path to config file (default: /etc/ushift/config.toml)
        \\  -h, --help            Print help
        \\
    ;

    const params = comptime clap.parseParamsComptime(options);
    const parsers = comptime .{
        .FILE = clap.parsers.string,
        .BATNAME = clap.parsers.string,
        .BAT_LEVEL = clap.parsers.int(u8, 10),
        .POLLRATE = clap.parsers.int(u32, 10),
        .GPU_INDEX = clap.parsers.int(u32, 10),
        .LOG_LEVEL = clap.parsers.enumeration(std.log.Level),
    };

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        report(diag, err);
        try printUsage(io, &params, "laptop");
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("{s}{s}\n", .{ help, options });
        return .noop;
    }
    if (res.args.@"log-level") |level| {
        log.setLevel(level);
    }

    return .{ .daemon = .{
        .config_file = res.args.config,
        .bat_name = res.args.@"bat-name",
        .low_level = res.args.@"low-level",
        .poll_rate = res.args.@"poll-rate",
        .gpu_index = res.args.@"gpu-index",
    } };
}

fn showConfig(
    io: std.Io,
    gpa: std.mem.Allocator,
    iter: *std.process.Args.Iterator,
) !Parsed {
    const help =
        \\Print config file
        \\
        \\Usage: ushift cfg [OPTIONS]
        \\
        \\Options:
    ;

    const options =
        \\  -c, --config <FILE>   Path to config file (default: /etc/ushift/config.toml)
        \\  -h, --help            Print help
        \\
    ;

    const params = comptime clap.parseParamsComptime(options);
    const parsers = comptime .{
        .FILE = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, parsers, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        report(diag, err);
        try printUsage(io, &params, "cfg");
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("{s}\n{s}\n", .{ help, options });
        return .noop;
    }
    return .{ .showcfg = .{ .file = res.args.config } };
}

fn info(
    comptime component: enum { cpu, gpu },
    io: std.Io,
    gpa: std.mem.Allocator,
    iter: *std.process.Args.Iterator,
) !Parsed {
    var help_buf: [256]u8 = undefined;
    const help = try std.fmt.bufPrint(&help_buf,
        \\Print {s} info
        \\
        \\Usage: ushift {s} [OPTIONS]
        \\
        \\Options:
        \\
    , .{ if (component == .cpu) "CPU" else "GPU", @tagName(component) });

    const options =
        \\  -h, --help    Print help
        \\
    ;

    const params = comptime clap.parseParamsComptime(options);

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        report(diag, err);
        try printUsage(io, &params, @tagName(component));
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("{s}{s}\n", .{ help, options });
        return .noop;
    }

    return switch (component) {
        .cpu => .{ .info = .cpu },
        .gpu => .{ .info = .gpu },
    };
}

fn powerSupply(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !Parsed {
    const help =
        \\Print power supply info (battery/AC)
        \\
        \\Usage: ushift pows [OPTIONS]
        \\
        \\Options:
        \\
    ;

    const options =
        \\  -h, --help    Print help
        \\
    ;

    const params = comptime clap.parseParamsComptime(options);
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        report(diag, err);
        try printUsage(io, &params, "pows");
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("{s}{s}\n", .{ help, options });
        return .noop;
    }

    return .power_supply;
}

fn printUsage(io: std.Io, params: anytype, subcmd: ?[]const u8) !void {
    if (subcmd) |cmd| {
        std.debug.print("Usage: {s} {s} ", .{ bin_name, cmd });
    } else {
        std.debug.print("Usage: {s} ", .{bin_name});
    }
    try clap.usageToFile(io, .stdout(), clap.Help, params);
    std.debug.print("\n", .{});
}

// based on https://hejsil.github.io/zig-clap/#test.Diagnostic.report
fn report(diag: clap.Diagnostic, err: anyerror) void {
    var longest = diag.name.longest();
    if (longest.kind == .positional)
        longest.name = diag.arg;

    switch (err) {
        error.DoesntTakeValue => std.log.err(
            "The argument '{s}{s}' does not take a value",
            .{ longest.kind.prefix(), longest.name },
        ),
        error.MissingValue => std.log.err(
            "The argument '{s}{s}' requires a value but none was supplied",
            .{ longest.kind.prefix(), longest.name },
        ),
        error.InvalidArgument => std.log.err(
            "Invalid argument '{s}{s}'",
            .{ longest.kind.prefix(), longest.name },
        ),
        error.NameNotPartOfEnum => std.log.err("Invalid command", .{}),
        else => std.log.err("Error while parsing arguments: {s}", .{@errorName(err)}),
    }
}
