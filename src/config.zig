// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Pierre Dommerc

const std = @import("std");
const toml = @import("toml");
const Profile = @import("cli.zig").Profile;

const default_config_file = "/etc/ushift/config.toml";

pub const UserConfig = struct {
    battery_low: u8 = 20,
    battery_poll_rate: u32 = 30, // sec
    battery_name: ?[]const u8 = null, // sysfs device name, e.g. BAT0, BAT1, etc.
    battery_start_charge_threshold: ?u32 = null,
    battery_end_charge_threshold: ?u32 = null,
    // restore configured charge thresholds when AC is unplugged
    restore_charge_thresholds_on_bat: bool = true,
    performance: Profile = Profile.default(.performance),
    balance: Profile = Profile.default(.balance),
    save: ?Profile = null,
};

fn joinPath(buf: []u8, path: toml.FieldPath) []const u8 {
    if (path.len == 0) return "<root>";
    var w = std.Io.Writer.fixed(buf);
    for (path, 0..) |segment, i| {
        if (i > 0) w.writeByte('.') catch break;
        w.writeAll(segment) catch break;
    }
    return w.buffered();
}

fn logParseError(path: []const u8, err: anyerror, info: ?toml.ErrorInfo) void {
    var buf: [256]u8 = undefined;
    const einfo = info orelse {
        std.log.err("failed to parse config file '{s}': {s}", .{ path, @errorName(err) });
        return;
    };
    switch (einfo) {
        .parse => |pos| std.log.err(
            "failed to parse config file '{s}': {s} at line {d}, column {d}",
            .{ path, @errorName(err), pos.line, pos.pos },
        ),
        .unknown_fields => |u| {
            const table = joinPath(&buf, u.path);
            for (u.keys) |key| {
                std.log.err(
                    "failed to parse config file '{s}': unknown field '{s}' in '{s}'",
                    .{ path, key, table },
                );
            }
        },
        .struct_mapping => |field_path| {
            const field = joinPath(&buf, field_path);
            switch (err) {
                error.InvalidValueType => std.log.err(
                    "failed to parse config file '{s}': invalid value type for field '{s}'",
                    .{ path, field },
                ),
                error.MissingRequiredField => std.log.err(
                    "failed to parse config file '{s}': missing required field '{s}'",
                    .{ path, field },
                ),
                else => std.log.err(
                    "failed to parse config file '{s}': {s} for field '{s}'",
                    .{ path, @errorName(err), field },
                ),
            }
        },
    }
}

pub const Config = struct {
    parsed: toml.Parsed(UserConfig),

    pub fn load(io: std.Io, allocator: std.mem.Allocator, config_path: ?[]const u8) !Config {
        var parser = toml.Parser(UserConfig).init(allocator);
        parser.options.disallow_unknown_fields = true;
        defer parser.deinit();

        const path = config_path orelse default_config_file;
        std.log.debug("config file '{s}'", .{path});

        const result = parser.parseFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.err("failed to open config file '{s}': {s}", .{ path, @errorName(err) });
                return error.ConfigFileOpen;
            },
            else => {
                logParseError(path, err, parser.error_info);
                return error.ConfigFileParse;
            },
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
