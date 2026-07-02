// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Pierre Dommerc

const std = @import("std");
const fs = @import("fs.zig");
const Profile = @import("cli.zig").Profile;

const drm_dir = "/sys/class/drm";

// sysfs attribute /sys/class/drm/card0/device/tile*/gt*/freq*/power_profile
pub const XePowerProfile = enum {
    base,
    power_saving,
};

// https://docs.kernel.org/gpu/amdgpu/thermal.html#power-dpm-force-performance-level
pub const RadeonDpmPerfLevel = enum {
    auto,
    low,
    high,
    manual,
    profiling, // no need to know the specific profile
};

// supported subset of RadeonDpmPerfLevel as user input
pub const UserRadeonDpmPerfLevel = enum {
    auto,
    low,
    high,
};

pub const Driver = enum {
    xe, // intel newer Xe/Arc (i)gpus
    i915,
    amdgpu,
    radeon,
    nouveau,
    nvidia,
    // others
    unknown,
};

pub const Card = struct {
    idx: u32,
    driver: ?Driver,

    pub fn print(self: *const Card, comptime option: struct {
        logger: enum { print, log } = .print,
    }) void {
        const driver = if (self.driver) |drv| @tagName(drv) else "no driver";
        switch (option.logger) {
            .print => std.debug.print(
                "card[{d}] driver {s} ({s}/card{d})\n",
                .{ self.idx, driver, drm_dir, self.idx },
            ),
            .log => std.log.info(
                "card[{d}] driver {s} ({s}/card{d})",
                .{ self.idx, driver, drm_dir, self.idx },
            ),
        }
    }
};

pub const Gpu = struct {
    cards: []Card,

    var _gpa: std.mem.Allocator = undefined;
    var _io: std.Io = undefined;

    const Self = @This();

    const DriverActionType = enum { xe, amd };
    const DriverAction = union(enum) {
        print,
        set: union(enum) {
            xe: XePowerProfile,
            amd: UserRadeonDpmPerfLevel,
        },
    };

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !Self {
        _gpa = gpa;
        _io = io;

        var buf: [32]u32 = undefined;
        const gpus = try fs.collectDirItems(32, io, &buf, .{
            .file_kind = .sym_link,
            .path = drm_dir,
            .prefix = "card",
        });

        var cards = try std.ArrayList(Card).initCapacity(gpa, gpus.len);
        errdefer cards.deinit(gpa);

        for (gpus) |num| {
            const driver = try getDriver(io, num);
            const dvr_str = if (driver) |drv| @tagName(drv) else "no driver";
            std.log.debug("GPU card{d} driver {s}", .{ num, dvr_str });
            cards.appendAssumeCapacity(Card{
                .idx = num,
                .driver = driver,
            });
        }

        return Self{
            .cards = try cards.toOwnedSlice(gpa),
        };
    }

    pub fn driverAction(
        self: *const Self,
        comptime driver: DriverActionType,
        action: DriverAction,
        gpu_index: ?u32,
    ) !void {
        if (self.cards.len == 0) {
            std.log.warn("no GPU found in '{s}'", .{drm_dir});
            return error.NoGpuFound;
        }
        if (gpu_index) |idx| {
            const card = self.findCard(idx) orelse {
                const indexes = try self.getCardIndexes();
                defer _gpa.free(indexes);
                std.log.err("GPU card{d} not found, available card index: {s}", .{ idx, indexes });
                return error.GpuBadIndex;
            };
            switch (driver) {
                .xe => if (card.driver != .xe) {
                    std.log.err(
                        "GPU card{d} driver is not xe: {s}",
                        .{ card.idx, @tagName(card.driver orelse .unknown) },
                    );
                    return error.GpuBadIndex;
                },
                .amd => if (card.driver != .amdgpu and card.driver != .radeon) {
                    std.log.err(
                        "GPU card{d} driver is not amdgpu or radeon: {s}",
                        .{ card.idx, @tagName(card.driver orelse .unknown) },
                    );
                    return error.GpuBadIndex;
                },
            }
            try applyDriverAction(driver, action, card);
        } else {
            const cards = switch (driver) {
                .xe => try self.filterCardsByDriver(.xe),
                .amd => try self.filterCardsAmd(),
            };
            defer _gpa.free(cards);
            if (cards.len == 0) {
                std.log.warn("no GPU found for driver {s}", .{
                    if (driver == .xe) "xe" else "amdgpu or radeon",
                });
                return error.NoGpuFound;
            }
            for (cards) |card| try applyDriverAction(driver, action, card);
        }
    }

    fn applyDriverAction(
        comptime driver: DriverActionType,
        action: DriverAction,
        card: Card,
    ) !void {
        switch (driver) {
            .xe => switch (action) {
                .print => try cardPrintXePP(_gpa, _io, card.idx),
                .set => |d| switch (d) {
                    .xe => |profile| try cardSetXePP(_gpa, _io, card.idx, profile),
                    else => unreachable,
                },
            },
            .amd => switch (action) {
                .print => try cardPrintRadeonDpmLvl(_io, card.idx),
                .set => |d| switch (d) {
                    .amd => |level| try cardSetRadeonDpmLvl(_io, card.idx, level),
                    else => unreachable,
                },
            },
        }
    }

    pub fn setProfile(self: *const Self, profile: *const Profile) !void {
        var err_hit: bool = false;
        if (profile.intel_xe_power_profile) |p| {
            self.driverAction(.xe, .{ .set = .{ .xe = p } }, null) catch |err| {
                std.log.err("failed to set Xe power profile: {s}", .{@errorName(err)});
                err_hit = true;
            };
        }
        if (profile.radeon_dpm_perf_level) |level| {
            self.driverAction(.amd, .{ .set = .{ .amd = level } }, null) catch |err| {
                std.log.err("failed to set Radeon DPM perf level: {s}", .{@errorName(err)});
                err_hit = true;
            };
        }
        if (err_hit) {
            return error.ApplyProfileFailed;
        }
    }

    pub fn print(self: *const Self) void {
        for (self.cards) |card|
            card.print(.{ .logger = .print });
    }

    // caller owns the returned slice
    fn getCardIndexes(self: *const Self) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(_gpa);
        for (self.cards, 0..) |card, i| {
            if (i > 0) try buf.print(_gpa, ", ", .{});
            try buf.print(_gpa, "{d}", .{card.idx});
        }
        return buf.toOwnedSlice(_gpa);
    }

    fn findCard(self: *const Self, index: u32) ?Card {
        for (self.cards) |card| if (card.idx == index) return card;
        return null;
    }

    /// caller owns the returned slice
    fn filterCardsByDriver(self: *const Self, driver: Driver) ![]Card {
        var filtered: std.ArrayList(Card) = try .initCapacity(_gpa, self.cards.len);
        for (self.cards) |card| if (card.driver == driver)
            filtered.appendAssumeCapacity(card);
        return try filtered.toOwnedSlice(_gpa);
    }

    /// caller owns the returned slice
    fn filterCardsAmd(self: *const Self) ![]Card {
        var filtered: std.ArrayList(Card) = try .initCapacity(_gpa, self.cards.len);
        for (self.cards) |card| if (card.driver == .amdgpu or card.driver == .radeon)
            filtered.appendAssumeCapacity(card);
        return try filtered.toOwnedSlice(_gpa);
    }

    pub fn deinit(self: *Self) void {
        _gpa.free(self.cards);
    }
};

fn getDriver(io: std.Io, card: u32) !?Driver {
    var buf: [2048]u8 = undefined;
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/card{d}/device/driver", .{ drm_dir, card });
    const n = std.Io.Dir.readLinkAbsolute(io, path, &buf) catch |err|
        switch (err) {
            error.FileNotFound, error.NotLink => {
                std.log.warn("no driver found for card{d}", .{card});
                return null;
            },
            else => {
                std.log.err("failed to get driver for card{d}: {s}", .{ card, @errorName(err) });
                return err;
            },
        };
    if (n == 0) return error.BadDriver;
    const driver = std.Io.Dir.path.basename(buf[0..n]);
    return std.meta.stringToEnum(Driver, driver) orelse .unknown;
}

fn cardPrintXePP(gpa: std.mem.Allocator, io: std.Io, index: u32) !void {
    const paths = try discoverXePowerProfiles(gpa, io, index);
    defer {
        for (paths) |p| gpa.free(p);
        gpa.free(paths);
    }

    for (paths) |path| {
        var buf: [256]u8 = undefined;
        const profile = fs.readLine(256, io, path, &buf, .{ .trim = true }) catch |err| {
            std.log.err("failed to read Xe power profile ({s}): {s}", .{ path, @errorName(err) });
            return err;
        } orelse continue;
        std.debug.print("card{d} Xe power profile: ⌜{s}⌟ ({s})\n", .{ index, profile, path });
    }
}

fn cardSetXePP(
    gpa: std.mem.Allocator,
    io: std.Io,
    index: u32,
    profile: XePowerProfile,
) !void {
    const paths = try discoverXePowerProfiles(gpa, io, index);
    defer {
        for (paths) |p| gpa.free(p);
        gpa.free(paths);
    }

    for (paths) |path| {
        std.debug.print(
            "[card{d}] setting Xe power profile to '{s}' ({s})\n",
            .{ index, @tagName(profile), path },
        );
        try fs.writeFile(io, path, @tagName(profile));
    }
}

fn cardPrintRadeonDpmLvl(io: std.Io, index: u32) !void {
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buf,
        "{s}/card{d}/device/power_dpm_force_performance_level",
        .{ drm_dir, index },
    );

    var level_buf: [256]u8 = undefined;
    const level = fs.readLine(256, io, path, &level_buf, .{}) catch |err| {
        std.log.err("failed to read Radeon DPM perf level ({s}): {s}", .{ path, @errorName(err) });
        return err;
    } orelse return error.SysfsReadEmpty;
    std.debug.print("card{d} Radeon DPM perf level: [{s}] ({s})\n", .{ index, level, path });
}

fn cardSetRadeonDpmLvl(
    io: std.Io,
    index: u32,
    level: UserRadeonDpmPerfLevel,
) !void {
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buf,
        "{s}/card{d}/device/power_dpm_force_performance_level",
        .{ drm_dir, index },
    );

    std.debug.print(
        "[card{d}] setting Radeon DPM perf level to '{s}' ({s})\n",
        .{ index, @tagName(level), path },
    );
    try fs.writeFile(io, path, @tagName(level));
}

/// Discover Xe GT power_profile filepaths, matching:
///   `/sys/class/drm/card0/device/tile*/gt*/freq*/power_profile`
/// https://docs.kernel.org/gpu/xe/xe_tile.html
/// Caller owns the returned slice and allocated memory
fn discoverXePowerProfiles(gpa: std.mem.Allocator, io: std.Io, card_num: u32) ![][]u8 {
    var path_buf: [256]u8 = undefined;
    const root_path = try std.fmt.bufPrint(&path_buf, "{s}/card{d}/device", .{ drm_dir, card_num });
    const dir = std.Io.Dir.openDirAbsolute(io, root_path, .{ .iterate = true }) catch |err| {
        std.log.err("failed to open directory '{s}': {s}", .{ root_path, @errorName(err) });
        return err;
    };
    defer dir.close(io);

    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();

    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }

    while (try walker.next(io)) |entry| {
        switch (entry.depth()) {
            1 => if (entry.kind == .directory and hasDigitSuffix(entry.basename, "tile"))
                try walker.enter(io, entry),
            2 => if (entry.kind == .directory and hasDigitSuffix(entry.basename, "gt"))
                try walker.enter(io, entry),
            3 => if (entry.kind == .directory and hasDigitSuffix(entry.basename, "freq"))
                try walker.enter(io, entry),
            4 => if (std.mem.eql(u8, entry.basename, "power_profile"))
                try paths.append(gpa, try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root_path, entry.path })),
            else => {},
        }
    }

    return paths.toOwnedSlice(gpa);
}

fn hasDigitSuffix(s: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, s, prefix)) return false;
    const suffix = s[prefix.len..];
    if (suffix.len == 0) return false;
    for (suffix) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

const testing = std.testing;
test "gpu_init" {
    var gpu = try Gpu.init(testing.allocator, testing.io);
    defer gpu.deinit();
    gpu.print();
}

test "intel_xe_power_profiles" {
    const profiles = try discoverXePowerProfiles(testing.allocator, testing.io, 0);
    for (profiles) |p| {
        std.debug.print("[XE] {s}\n", .{p});
        testing.allocator.free(p);
    }
    testing.allocator.free(profiles);
}

test "driver_action" {
    var gpu = try Gpu.init(testing.allocator, testing.io);
    defer gpu.deinit();
    try gpu.driverAction(.xe, .print, null);
    // try gpu.driverAction(.amd, .print, null);
}
