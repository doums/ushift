// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Pierre Dommerc

const std = @import("std");
const fs = @import("fs.zig");

const power_supply_sysfs = "/sys/class/power_supply";

// whether sysfs exposes the battery capacity as charge (µAh) or energy (µWh)
// ie. charge_now/charge_full or energy_now/energy_full
pub const BatteryCapacityPrefix = enum {
    charge,
    energy,
};

pub fn printPowerSupply(gpa: std.mem.Allocator, io: std.Io) !void {
    const ps = try getPowerSupply(gpa, io, false);
    defer {
        gpa.free(ps.bat);
        gpa.free(ps.ac);
    }

    const cap_prefix = try getBatteryCapacityPrefix(io, ps.bat);
    const ac_online = try readAcOnline(io, ps.ac);
    const bat_cap = try readBatteryCapacity(io, ps.bat, cap_prefix);
    std.debug.print(
        \\{s}: capacity {d}% ({s}/{s})
        \\{s}: online {s} ({s}/{s})
        \\
    , .{
        ps.bat,
        bat_cap,
        power_supply_sysfs,
        ps.bat,
        ps.ac,
        if (ac_online) "yes" else "no",
        power_supply_sysfs,
        ps.ac,
    });
}

// Find battery and AC devices in /sys/class/power_supply
// callers owns the memory
pub fn getPowerSupply(gpa: std.mem.Allocator, io: std.Io, log: bool) !struct {
    bat: []u8,
    ac: []u8,
} {
    const dir = std.Io.Dir.openDirAbsolute(io, power_supply_sysfs, .{ .iterate = true }) catch |err| {
        std.log.err("failed to open directory '{s}': {s}", .{ power_supply_sysfs, @errorName(err) });
        return error.NoBattery;
    };
    defer dir.close(io);
    var bat_name: ?[]u8 = null;
    var ac_name: ?[]u8 = null;
    errdefer {
        if (bat_name) |v| gpa.free(v);
        if (ac_name) |v| gpa.free(v);
    }
    var it = dir.iterate();

    while (try it.next(io)) |entry| {
        if (entry.kind != std.Io.File.Kind.directory and
            entry.kind != std.Io.File.Kind.sym_link)
            continue;

        var path_buf: [256]u8 = undefined;
        var type_buf: [256]u8 = undefined;
        const type_path = std.fmt.bufPrint(&path_buf, "{s}/{s}/type", .{ power_supply_sysfs, entry.name }) catch continue;
        const dev_type = try fs.readLine(256, io, type_path, &type_buf, .{}) orelse continue;
        if (std.mem.eql(u8, dev_type, "Battery")) {
            if (log) std.log.info("found battery: {s}", .{entry.name});
            bat_name = try gpa.dupe(u8, entry.name);
        }
        if (std.mem.eql(u8, dev_type, "Mains")) {
            if (log) std.log.info("found AC device: {s}", .{entry.name});
            ac_name = try gpa.dupe(u8, entry.name);
        }
        if (bat_name != null and ac_name != null) break;
    }
    if (bat_name == null) {
        std.log.err("no battery found in {s}", .{power_supply_sysfs});
        return error.NoBattery;
    }
    if (ac_name == null) {
        std.log.err("no AC device found in {s}", .{power_supply_sysfs});
        return error.NoAC;
    }
    return .{
        .bat = bat_name.?,
        .ac = ac_name.?,
    };
}

pub fn checkUserBattery(io: std.Io, bat: []const u8) !bool {
    var path_buf: [256]u8 = undefined;
    var bat_type_buf: [256]u8 = undefined;

    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/type", .{ power_supply_sysfs, bat });
    const bat_type = fs.readLine(256, io, path, &bat_type_buf, .{}) catch |err|
        switch (err) {
            error.FileNotFound => return false,
            else => return error.InvalidBattery,
        } orelse return error.InvalidBattery;

    if (!std.mem.eql(u8, bat_type, "Battery")) {
        std.log.err("user battery '{s}' is not a battery (type={s})", .{ bat, bat_type });
        return false;
    }
    return true;
}

fn checkCapacityAttribute(comptime prefix: BatteryCapacityPrefix, io: std.Io, bat: []const u8) !bool {
    var path_buf: [256]u8 = undefined;

    const energy_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}_full", .{
        power_supply_sysfs,
        bat,
        @tagName(prefix),
    });
    if (try fs.fileExists(io, energy_path)) {
        return true;
    }

    return false;
}

pub fn getBatteryCapacityPrefix(io: std.Io, bat: []const u8) !BatteryCapacityPrefix {
    if (try checkCapacityAttribute(.energy, io, bat)) {
        return .energy;
    }
    if (try checkCapacityAttribute(.charge, io, bat)) {
        return .charge;
    }
    std.log.err("sysfs for battery '{s}' does not expose energy or charge capacity attribute", .{bat});
    return error.SysfsBatCapNotFound;
}

pub fn readBatteryCapacityKind(
    comptime kind: enum { full, now },
    io: std.Io,
    bat: []const u8,
    prefix: BatteryCapacityPrefix,
) !u32 {
    var path_buf: [256]u8 = undefined;
    var buf: [32]u8 = undefined;

    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}_{s}", .{
        power_supply_sysfs,
        bat,
        @tagName(prefix),
        @tagName(kind),
    });
    const val = try fs.readLine(32, io, path, &buf, .{}) orelse return error.SysfsBatCapRead;

    return std.fmt.parseInt(u32, val, 10) catch
        return error.SysfsBatCapParse;
}

pub fn readBatteryCapacity(
    io: std.Io,
    bat: []const u8,
    prefix: BatteryCapacityPrefix,
) !u32 {
    const full: f64 = @floatFromInt(try readBatteryCapacityKind(.full, io, bat, prefix));
    const now: f64 = @floatFromInt(try readBatteryCapacityKind(.now, io, bat, prefix));

    if (full == 0) {
        std.log.err("battery '{s}' has full capacity of 0", .{bat});
        return error.SysfsBatCapFullZero;
    }

    const percent = @min(@as(u32, @round((now * 100) / full)), 100); // clamp to 100% max
    std.log.debug("battery '{s}' capacity: {d}/{d} ({d}%)", .{ bat, now, full, percent });
    return percent;
}

pub fn readAcOnline(io: std.Io, ac: []const u8) !bool {
    var path_buf: [256]u8 = undefined;
    var buf: [32]u8 = undefined;

    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/online", .{ power_supply_sysfs, ac });
    const val = try fs.readLine(32, io, path, &buf, .{}) orelse return error.SysfsAcRead;

    if (std.mem.eql(u8, val, "1")) {
        return true;
    } else if (std.mem.eql(u8, val, "0")) {
        return false;
    } else {
        std.log.err("AC '{s}' online attribute unexpected value '{s}'", .{ ac, val });
        return error.SysfsAcParse;
    }
}
