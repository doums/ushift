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

pub const BatteryChargeThresholdKind = enum {
    start,
    end,
};

// sysfs battery charge threshold properties
// - charge_control_start_threshold, charge_control_end_threshold
// - charge_start_threshold, charge_stop_threshold (older kernels)
pub const BatteryChargeThresholdPrefix = enum {
    charge_control,
    charge,

    pub fn attributeName(
        self: BatteryChargeThresholdPrefix,
        kind: BatteryChargeThresholdKind,
    ) []const u8 {
        return switch (kind) {
            .start => switch (self) {
                .charge_control => "charge_control_start_threshold",
                .charge => "charge_start_threshold",
            },
            .end => switch (self) {
                .charge_control => "charge_control_end_threshold",
                .charge => "charge_stop_threshold",
            },
        };
    }
};

pub const Battery = struct {
    name: []u8,
    capacity_prefix: BatteryCapacityPrefix,
    // no prefix means charge threshold not supported
    charge_threshold_prefix: ?BatteryChargeThresholdPrefix,

    const Self = @This();

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        name: []const u8,
    ) !Self {
        const cap_prefix = try getBatteryCapacityPrefix(io, name);
        const charge_prefix = try getBatteryChargeThresholdPrefix(io, name);

        return Battery{
            .name = try gpa.dupe(u8, name),
            .capacity_prefix = cap_prefix,
            .charge_threshold_prefix = charge_prefix,
        };
    }

    pub fn readCapacity(
        self: *const Self,
        io: std.Io,
    ) !u32 {
        const full: f64 = @floatFromInt(try readBatteryCapacityKind(
            .full,
            io,
            self.name,
            self.capacity_prefix,
        ));
        const now: f64 = @floatFromInt(try readBatteryCapacityKind(
            .now,
            io,
            self.name,
            self.capacity_prefix,
        ));

        if (full == 0) {
            std.log.err("battery '{s}' has full capacity of 0", .{self.name});
            return error.SysfsBatCapFullZero;
        }

        const percent = @min(@as(u32, @round((now * 100) / full)), 100); // clamp to 100% max
        std.log.debug("battery '{s}' capacity: {d}/{d} ({d}%)", .{ self.name, now, full, percent });
        return percent;
    }

    pub fn readChargeThreshold(
        self: *const Self,
        io: std.Io,
        kind: BatteryChargeThresholdKind,
    ) !u32 {
        const prefix = self.charge_threshold_prefix orelse return error.BatteryChargeThresholdNotSupported;
        var path_buf: [256]u8 = undefined;
        var buf: [32]u8 = undefined;

        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}", .{
            power_supply_sysfs,
            self.name,
            prefix.attributeName(kind),
        });
        const val = try fs.readLine(32, io, path, &buf, .{}) orelse
            return error.SysfsBatChargeThresholdRead;

        return std.fmt.parseInt(u32, val, 10) catch
            return error.SysfsBatChargeThresholdParse;
    }

    pub fn setChargeThreshold(
        self: *const Self,
        io: std.Io,
        start: ?u32,
        end: ?u32,
    ) !void {
        const prefix = self.charge_threshold_prefix orelse return error.BatteryChargeThresholdNotSupported;
        if (start) |s| try setBatteryChargeThresholdKind(io, self.name, .{
            .kind = .start,
            .prefix = prefix,
            .value = s,
        });
        if (end) |e| try setBatteryChargeThresholdKind(io, self.name, .{
            .kind = .end,
            .prefix = prefix,
            .value = e,
        });
    }

    pub fn print(self: *const Self, io: std.Io) !void {
        var msg_buf: [512]u8 = undefined;
        var w = std.Io.Writer.fixed(&msg_buf);
        const cap = try self.readCapacity(io);

        try w.print(
            \\[{s}] ({s}/{s})
            \\  capacity: {d}% 
            \\
        , .{ self.name, power_supply_sysfs, self.name, cap });

        if (self.charge_threshold_prefix != null) {
            const start = try self.readChargeThreshold(io, .start);
            const end = try self.readChargeThreshold(io, .end);
            try w.print(
                \\  charge thresholds: {d}-{d}%
                \\
            , .{ start, end });
        } else {
            try w.print(
                \\{s}: charge thresholds not supported
                \\
            , .{self.name});
        }

        std.debug.print("{s}", .{w.buffered()});
    }

    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
    }
};

pub const Ac = struct {
    name: []const u8,

    const Self = @This();

    pub fn init(
        gpa: std.mem.Allocator,
        name: []const u8,
    ) !Self {
        return Ac{
            .name = try gpa.dupe(u8, name),
        };
    }

    pub fn readOnline(self: *const Self, io: std.Io) !bool {
        var path_buf: [256]u8 = undefined;
        var buf: [32]u8 = undefined;

        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/online", .{ power_supply_sysfs, self.name });
        const val = try fs.readLine(32, io, path, &buf, .{}) orelse return error.SysfsAcRead;

        if (std.mem.eql(u8, val, "1")) {
            return true;
        } else if (std.mem.eql(u8, val, "0")) {
            return false;
        } else {
            std.log.err("AC '{s}' online attribute unexpected value '{s}'", .{ self.name, val });
            return error.SysfsAcParse;
        }
    }

    pub fn print(self: *const Self, io: std.Io) !void {
        const online = try self.readOnline(io);
        std.debug.print("[{s}] online: {s} ({s}/{s})\n", .{
            self.name,
            if (online) "yes" else "no",
            power_supply_sysfs,
            self.name,
        });
    }

    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
    }
};

pub const PowerSupply = struct {
    batteries: []Battery,
    aces: []Ac,

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator, io: std.Io, log: bool) !Self {
        var batteries: std.ArrayList(Battery) = .empty;
        var aces: std.ArrayList(Ac) = .empty;
        errdefer {
            for (batteries.items) |*bat| bat.deinit(gpa);
            batteries.deinit(gpa);
            for (aces.items) |*ac| ac.deinit(gpa);
            aces.deinit(gpa);
        }

        const dir = std.Io.Dir.openDirAbsolute(
            io,
            power_supply_sysfs,
            .{ .iterate = true },
        ) catch |err| {
            std.log.err("failed to open directory '{s}': {s}", .{ power_supply_sysfs, @errorName(err) });
            return error.SysfsNoPowerSupply;
        };
        defer dir.close(io);

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
                try batteries.append(gpa, try Battery.init(gpa, io, entry.name));
            }
            if (std.mem.eql(u8, dev_type, "Mains")) {
                if (log) std.log.info("found AC device: {s}", .{entry.name});
                try aces.append(gpa, try Ac.init(gpa, entry.name));
            }
        }

        return PowerSupply{
            .batteries = try batteries.toOwnedSlice(gpa),
            .aces = try aces.toOwnedSlice(gpa),
        };
    }

    pub fn getBattery(self: *const Self, name: []const u8) ?*const Battery {
        for (self.batteries) |*bat| {
            if (std.mem.eql(u8, bat.name, name)) return bat;
        }
        return null;
    }

    pub fn print(self: *const Self, io: std.Io) !void {
        for (self.batteries) |bat| try bat.print(io);
        for (self.aces) |ac| try ac.print(io);
    }

    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        for (self.batteries) |*bat| bat.deinit(gpa);
        gpa.free(self.batteries);
        for (self.aces) |*ac| ac.deinit(gpa);
        gpa.free(self.aces);
    }
};

fn checkCapacityAttribute(comptime prefix: BatteryCapacityPrefix, io: std.Io, bat: []const u8) !bool {
    var path_buf: [256]u8 = undefined;

    const energy_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}_full", .{
        power_supply_sysfs,
        bat,
        @tagName(prefix),
    });
    return try fs.fileExists(io, energy_path);
}

fn getBatteryCapacityPrefix(io: std.Io, bat: []const u8) !BatteryCapacityPrefix {
    if (try checkCapacityAttribute(.energy, io, bat)) {
        return .energy;
    }
    if (try checkCapacityAttribute(.charge, io, bat)) {
        return .charge;
    }
    std.log.err("sysfs for battery '{s}' does not expose energy or charge capacity attribute", .{bat});
    return error.SysfsBatCapNotFound;
}

fn checkBatteryChargeThresholdAttribute(comptime prefix: BatteryChargeThresholdPrefix, io: std.Io, bat: []const u8) !bool {
    var path_buf: [256]u8 = undefined;

    const energy_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}_start_threshold", .{
        power_supply_sysfs,
        bat,
        @tagName(prefix),
    });
    return try fs.fileExists(io, energy_path);
}

fn getBatteryChargeThresholdPrefix(io: std.Io, bat: []const u8) !?BatteryChargeThresholdPrefix {
    // check for newer charge_control_start_threshold first
    if (try checkBatteryChargeThresholdAttribute(.charge_control, io, bat)) {
        return .charge_control;
    }
    if (try checkBatteryChargeThresholdAttribute(.charge, io, bat)) {
        return .charge;
    }
    std.log.info("sysfs charge threshold for battery '{s}' not supported", .{bat});
    return null;
}

fn readBatteryCapacityKind(
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

fn setBatteryChargeThresholdKind(io: std.Io, bat: []const u8, data: struct {
    kind: BatteryChargeThresholdKind,
    value: u32,
    prefix: BatteryChargeThresholdPrefix,
}) !void {
    var path_buf: [256]u8 = undefined;

    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}", .{
        power_supply_sysfs,
        bat,
        data.prefix.attributeName(data.kind),
    });

    var buf: [10]u8 = undefined;
    const thresh_str = try std.fmt.bufPrint(&buf, "{d}", .{data.value});
    try fs.writeFile(io, path, thresh_str);
}
