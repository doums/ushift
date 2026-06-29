// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Pierre Dommerc

const std = @import("std");
const Io = std.Io;

const drm_dir = "/sys/class/drm";

pub fn FileLineIterator(comptime bsize: usize) type {
    return struct {
        io: Io,
        path: []const u8,
        file: Io.File,
        reader: Io.File.Reader,

        var buf: [bsize]u8 = @splat(0);
        const Self = @This();

        pub fn init(io: Io, path: []const u8) Io.File.OpenError!Self {
            const file = Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
                std.log.err("failed to open file '{s}': {s}", .{ path, @errorName(err) });
                return err;
            };
            const reader = file.reader(io, &buf);

            return Self{
                .io = io,
                .path = path,
                .file = file,
                .reader = reader,
            };
        }

        pub fn next(self: *Self) !?[]u8 {
            const reader = &self.reader.interface;
            return reader.takeDelimiter('\n') catch |err| {
                std.log.err("failed to read '{s}': {s}", .{ self.path, @errorName(err) });
                return err;
            };
        }

        pub fn close(self: *Self) void {
            self.file.close(self.io);
            buf = @splat(0);
        }
    };
}

/// Read the first line of a file
/// caller owns the returned slice memory
/// NOTE: maximum line length is limited to 256 bytes
pub fn readLineAlloc(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    options: struct { comptime max_line_len: usize = 256, trim: bool = false },
) ![]u8 {
    var it = try FileLineIterator(options.max_line_len).init(io, path);
    defer it.close();

    const line = try it.next() orelse "";
    if (options.trim) {
        return try gpa.dupe(u8, std.mem.trim(u8, line, " \t\r\n"));
    } else {
        return try gpa.dupe(u8, line);
    }
}

/// Read the first line of a file
/// returns a slice of the buffered bytes
pub fn readLine(
    comptime max_line_len: usize,
    io: std.Io,
    path: []const u8,
    buf: *[max_line_len]u8,
    options: struct {
        trim: bool = false,
    },
) !?[]u8 {
    var it = try FileLineIterator(max_line_len).init(io, path);
    defer it.close();

    const line = try it.next() orelse return null;
    if (options.trim) {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        @memcpy(buf[0..trimmed.len], trimmed);
        return buf[0..trimmed.len];
    } else {
        @memcpy(buf[0..line.len], line);
        return buf[0..line.len];
    }
}

/// Read a file and get the whole content
/// caller owns the returned slice memory
pub fn readFileAlloc(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    options: struct { trim: bool = false },
) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    const content = cwd.readFileAlloc(io, path, gpa, .unlimited) catch |err| {
        std.log.err("failed to read file '{s}': {s}", .{ path, @errorName(err) });
        return err;
    };
    if (options.trim) {
        defer gpa.free(content);
        return try gpa.dupe(u8, std.mem.trim(u8, content, " \t\r\n"));
    }
    return content;
}

/// Check if a directory exists
pub fn dirExists(io: std.Io, path: []const u8) !bool {
    const dir = Io.Dir.openDirAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => {
            std.log.err("failed to open directory '{s}': {s}", .{ path, @errorName(err) });
            return err;
        },
    };
    defer dir.close(io);
    return true;
}

/// Check if a file exists
pub fn fileExists(io: std.Io, path: []const u8) !bool {
    const file = Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.IsDir => return false,
        else => {
            std.log.err("failed to open file '{s}': {s}", .{ path, @errorName(err) });
            return err;
        },
    };
    defer file.close(io);
    return true;
}

/// Write to a file. Override existing file, if the file does not exist create it.
pub fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    const cwd = Io.Dir.cwd();
    cwd.writeFile(io, .{
        .sub_path = path,
        .data = data,
    }) catch |err| {
        std.log.err("failed to write file '{s}': {s}", .{ path, @errorName(err) });
        return err;
    };
}

/// List a directory and get the entries
/// Call `close` after use to free resources
pub const DirIterator = struct {
    dir: Io.Dir,
    iterator: Io.Dir.Iterator,
    filter_file_kind: ?std.Io.File.Kind,
    filter_filename_starts_with: ?[]const u8,

    const Self = @This();

    pub fn init(io: std.Io, path: []const u8, options: struct {
        filter_file_kind: ?std.Io.File.Kind = null,
        filter_filename_starts_with: ?[]const u8 = null,
    }) !Self {
        const dir = Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err| {
            std.log.err("failed to open directory '{s}': {s}", .{ path, @errorName(err) });
            return err;
        };

        return Self{
            .dir = dir,
            .iterator = dir.iterate(),
            .filter_file_kind = options.filter_file_kind,
            .filter_filename_starts_with = options.filter_filename_starts_with,
        };
    }

    pub fn next(self: *Self, io: std.Io) !?[]const u8 {
        while (try self.iterator.next(io)) |entry| {
            if (self.filter_file_kind != null and
                entry.kind != self.filter_file_kind)
                continue;
            if (self.filter_filename_starts_with != null and
                !std.mem.startsWith(u8, entry.name, self.filter_filename_starts_with.?))
                continue;
            return entry.name;
        }
        return null;
    }

    pub fn close(self: *Self, io: std.Io) void {
        self.dir.close(io);
    }
};

/// Discover and collect the indexes of any child files
/// with a name matching the pattern `{prefix}{number}`.
pub fn collectDirItems(
    comptime max_size: usize,
    io: std.Io,
    items: *[max_size]u32,
    options: struct {
        file_kind: ?std.Io.File.Kind = .directory,
        path: []const u8,
        prefix: []const u8,
    },
) ![]u32 {
    var dirit = try DirIterator.init(io, options.path, .{
        .filter_file_kind = options.file_kind,
        .filter_filename_starts_with = options.prefix,
    });
    defer dirit.close(io);

    // use a bitset for free sorting
    const BitSet = std.bit_set.Static(max_size);
    var bitset = BitSet.empty;

    while (try dirit.next(io)) |dir| {
        const rest = std.mem.cutPrefix(u8, dir, options.prefix) orelse continue;
        const num = std.fmt.parseInt(u32, rest, 10) catch continue;
        if (num >= bitset.capacity()) {
            std.log.err("too many {s} ({d}), increase bitset capacity", .{ options.prefix, num });
            return error.TooManyObjects;
        }
        bitset.set(num);
    }

    var bitit = bitset.iterator(.{});
    var i: usize = 0;
    while (bitit.next()) |num| : (i += 1)
        items[i] = @intCast(num);
    std.debug.assert(i == bitset.count());

    return items[0..i];
}

const testing = std.testing;
test "file_line_iterator" {
    var it = try FileLineIterator(256).init(testing.io, "/etc/hosts");
    defer it.close();
    while (try it.next()) |line| {
        std.debug.print("[LIT] {s}\n", .{line});
    }
}

test "dir_iterator" {
    var it = try DirIterator.init(testing.io, "/sys/devices/system/cpu/", .{
        .filter_file_kind = .directory,
        .filter_filename_starts_with = "cpu",
    });
    defer it.close(testing.io);

    while (try it.next(testing.io)) |entry| {
        std.debug.print("[DIR] {s}\n", .{entry});
    }
}

test "collect_dir_objects" {
    var buf: [1024]u32 = undefined;
    const cpus = try collectDirItems(1024, testing.io, &buf, .{
        .file_kind = .directory,
        .path = "/sys/devices/system/cpu/",
        .prefix = "cpu",
    });
    std.debug.print("__cpus {any}\n", .{cpus});
    var buf2: [32]u32 = undefined;
    const gpus = try collectDirItems(32, testing.io, &buf2, .{
        .file_kind = .sym_link,
        .path = drm_dir,
        .prefix = "card",
    });
    std.debug.print("__gpus {any}\n", .{gpus});
}
