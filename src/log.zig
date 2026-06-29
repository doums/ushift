// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Pierre Dommerc

const std = @import("std");

var log_level: std.log.Level = std.log.default_level;

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(log_level)) return;
    std.log.defaultLog(level, scope, format, args);
}

pub fn setLevel(level: std.log.Level) void {
    log_level = level;
}
