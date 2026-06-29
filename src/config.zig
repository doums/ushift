// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Pierre Dommerc

const std = @import("std");
const toml = @import("toml");
const Profile = @import("cli.zig").Profile;

const default_config_file = "/etc/ushift/config.toml";

pub const UserConfig = struct {
    low_level: u8 = 20,
    bat_poll_rate: u32 = 30, // sec
    bat_name: ?[]const u8 = null, // sysfs device name, e.g. BAT0, BAT1, etc.
    gpu_index: u32 = 0,
    performance: Profile = Profile.default(.performance),
    balance: Profile = Profile.default(.balance),
    save: ?Profile = null,
};

pub const Config = struct {
    parsed: toml.Parsed(UserConfig),

    pub fn load(io: std.Io, allocator: std.mem.Allocator, config_path: ?[]const u8) !Config {
        var parser = toml.Parser(UserConfig).init(allocator);
        defer parser.deinit();

        const path = config_path orelse default_config_file;
        std.log.debug("config file '{s}'", .{path});
        checkFile(io, path) catch |err| {
            std.log.err("failed to open config file '{s}': {s}", .{ path, @errorName(err) });
            return error.ConfigFileOpen;
        };

        const result = parser.parseFile(io, path) catch |err| {
            std.log.err("failed to parse config file '{s}': {s}", .{ path, @errorName(err) });
            return error.ConfigFileParse;
        };

        return Config{
            .parsed = result,
        };
    }

    pub fn get(self: *const Config) UserConfig {
        return self.parsed.value;
    }

    pub fn print(self: *const Config) void {
        std.debug.print("{any}\n", .{self.parsed.value});
    }

    pub fn deinit(self: *const Config) void {
        self.parsed.deinit();
    }
};

fn checkFile(io: std.Io, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, path, .{ .allow_directory = false });
    defer file.close(io);
}
