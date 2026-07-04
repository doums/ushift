// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Pierre Dommerc

const std = @import("std");
const cfg = @import("config.zig");
const cli = @import("cli.zig");
const log = @import("log.zig");
const Ushift = @import("ushift.zig").Ushift;

pub const std_options: std.Options = .{
    .logFn = log.logFn,
    // Force comptime gate to .debug so all log call sites reach logFn.
    // Without this, Release builds dead-code-eliminate .debug calls
    // at compile time.
    .log_level = .debug,
};

pub fn main(init: std.process.Init) !u8 {
    // WIP in dev use this allocator
    // const gpa = init.gpa;
    const gpa = init.arena.allocator();

    const parsed = cli.cli(init.minimal.args, init.io, gpa) catch |err|
        return if (err == error.ParseCaught) 1 else err;
    std.log.debug("cli parsed: {any}", .{parsed});

    if (parsed == .noop) {
        return 0;
    }

    const config = switch (parsed) {
        .showcfg => |opt| try cfg.Config.load(init.io, gpa, opt.file),
        .set_profile => |opt| try cfg.Config.load(init.io, gpa, opt.config_file),
        .daemon => |opt| try cfg.Config.load(init.io, gpa, opt.config_file),
        else => null,
    };
    defer if (config) |conf| conf.deinit();

    if (parsed == .showcfg) {
        config.?.print();
        return 0;
    }

    var ushift = try Ushift.init(gpa, init.io);
    defer ushift.deinit();

    const userconf = if (config) |conf| conf.get() else cfg.UserConfig{};
    try ushift.dispatch(parsed, &userconf);

    return 0;
}
