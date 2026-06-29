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
    id: u32,
    driver: ?Driver,
};

pub const Gpu = struct {
    cards: []Card,

    var _gpa: std.mem.Allocator = undefined;
    var _io: std.Io = undefined;

    const Self = @This();

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
            std.log.debug("GPU{d} driver {s}", .{ num, dvr_str });
            cards.appendAssumeCapacity(Card{
                .id = num,
                .driver = driver,
            });
        }

        return Self{
            .cards = try cards.toOwnedSlice(gpa),
        };
    }

    pub fn printXePowerProfile(self: *const Self, card_num: u32) !void {
        const card = self.getCard(card_num) orelse {
            const indexes_str = try self.getCardIndexes();
            defer _gpa.free(indexes_str);
            std.debug.print("GPU{d} bad index, valid GPU index: {s}\n", .{ card_num, indexes_str });
            return error.GpuInvalidIndex;
        };
        if (card.driver != .xe) {
            std.debug.print("GPU{d} driver is not Xe\n", .{card_num});
            return error.NotXeGpu;
        }

        const paths = try discoverXePowerProfiles(_gpa, _io, card_num);
        defer {
            for (paths) |p| _gpa.free(p);
            _gpa.free(paths);
        }

        for (paths) |path| {
            var buf: [256]u8 = undefined;
            const profile = fs.readLine(256, _io, path, &buf, .{ .trim = true }) catch |err| {
                std.log.err("failed to read Xe power profile ({s}): {s}", .{ path, @errorName(err) });
                return err;
            } orelse continue;
            std.debug.print("card{d} Xe power profile: ⌜{s}⌟ ({s})\n", .{ card_num, profile, path });
        }
    }

    pub fn setXePowerProfile(self: *const Self, profile: XePowerProfile, card_num: u32) !void {
        if (self.cards.len == 0) {
            std.log.warn("no GPU found", .{});
            return error.NoGpuFound;
        }
        const card = self.getCard(card_num) orelse {
            const indexes_str = try self.getCardIndexes();
            defer _gpa.free(indexes_str);
            std.log.warn("GPU{d} bad index, valid GPU index: {s}", .{ card_num, indexes_str });
            return error.GpuInvalidIndex;
        };
        if (card.driver != .xe) {
            std.log.warn("GPU{d} driver is not Xe", .{card_num});
            return error.NotXeGpu;
        }

        const paths = try discoverXePowerProfiles(_gpa, _io, card_num);
        defer {
            for (paths) |p| _gpa.free(p);
            _gpa.free(paths);
        }

        for (paths) |path| {
            std.debug.print("[card{d}] setting Xe power profile to '{s}' ({s})\n", .{ card_num, @tagName(profile), path });
            try fs.writeFile(_io, path, @tagName(profile));
        }
    }

    pub fn setProfile(self: *const Self, profile: *const Profile, card_num: ?u32) !void {
        var err_hit: bool = false;
        if (profile.xe_power_profile) |mode| {
            self.setXePowerProfile(mode, card_num orelse 0) catch |err| {
                std.log.err("failed to set Xe power profile: {s}", .{@errorName(err)});
                err_hit = true;
            };
        }
        if (err_hit) {
            return error.ApplyProfileFailed;
        }
    }

    pub fn print(self: *const Self) void {
        for (self.cards) |card| {
            const driver = if (card.driver) |drv|
                @tagName(drv)
            else
                "no driver";

            std.debug.print("[{d}] driver: {s} ({s}/card{d})\n", .{ card.id, driver, drm_dir, card.id });
        }
    }

    // caller owns the returned slice
    fn getCardIndexes(self: *const Self) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(_gpa);
        for (self.cards, 0..) |card, i| {
            if (i > 0) try buf.print(_gpa, ", ", .{});
            try buf.print(_gpa, "{d}", .{card.id});
        }
        return buf.toOwnedSlice(_gpa);
    }

    pub fn getCard(self: *const Self, num: u32) ?Card {
        for (self.cards) |card| {
            if (card.id == num) return card;
        }
        return null;
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
    // std.debug.print("[GPU] card{d} driver: {s}\n", .{ card, driver });
    return std.meta.stringToEnum(Driver, driver) orelse .unknown;
}

/// Discover Xe GT power_profile filepaths, matching:
///   `/sys/class/drm/card0/device/tile*/gt*/freq*/power_profile`
/// https://docs.kernel.org/gpu/xe/xe_tile.html
/// Caller owns the returned slice and allocated memory
pub fn discoverXePowerProfiles(gpa: std.mem.Allocator, io: std.Io, card_num: u32) ![][]u8 {
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

test "xe_power_profiles" {
    const profiles = try discoverXePowerProfiles(testing.allocator, testing.io, 0);
    for (profiles) |p| {
        std.debug.print("[XE] {s}\n", .{p});
        testing.allocator.free(p);
    }
    testing.allocator.free(profiles);
}

test "set_xe_power_profile" {
    var gpu = try Gpu.init(testing.allocator, testing.io);
    defer gpu.deinit();
    try gpu.setXePowerProfile(.base, 0);
}
