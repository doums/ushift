// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Pierre Dommerc

const std = @import("std");
const fs = @import("fs.zig");
const cpu = @import("cpu.zig");

const proc_info = "/proc/cpuinfo";
const ProcProps = enum {
    model_name,
    vendor_id,
    microcode,
    cpu_cores,
    intel_epp,
    intel_epb,
};
const ProcInfoMap = std.EnumMap(ProcProps, []const u8);

pub const ProcInfo = struct {
    model_name: ?[]const u8,
    vendor_id: ?[]const u8,
    microcode: ?[]const u8,
    cpu_cores: ?u32,
    intel_epp: bool,
    intel_epb: bool,

    const Self = @This();

    // static lifetime, cleared after parsing
    var props: ProcInfoMap = undefined;

    pub fn parse(gpa: std.mem.Allocator, io: std.Io, vendor: cpu.Vendor) !ProcInfo {
        props = ProcInfoMap.init(.{});
        defer {
            // those are useless after parsing
            if (props.get(.cpu_cores)) |v| {
                gpa.free(v);
            }
            if (props.get(.intel_epp)) |v| {
                gpa.free(v);
            }
            if (props.get(.intel_epb)) |v| {
                gpa.free(v);
            }
            props = undefined;
        }
        // catch OOM scenario
        errdefer {
            if (props.get(.model_name)) |v| {
                gpa.free(v);
            }
            if (props.get(.vendor_id)) |v| {
                gpa.free(v);
            }
            if (props.get(.microcode)) |v| {
                gpa.free(v);
            }
        }

        // use 4096 bytes buffer for flags line which can be very long
        var lines_it = try fs.FileLineIterator(4096).init(io, proc_info);
        defer lines_it.close();
        while (try lines_it.next()) |line| {
            // exit reading asap
            if (vendor == .intel and props.count() == 6) {
                break;
            } else if (vendor != .intel and props.count() >= 4) {
                break;
            }
            // std.debug.print("[LIT] {s}\n", .{line});
            var it = std.mem.splitScalar(u8, line, ':');
            const key = trimWhitespace(it.first());
            if (it.next()) |val| {
                if (std.mem.eql(u8, key, "model name") and !props.contains(.model_name)) {
                    props.put(.model_name, try gpa.dupe(u8, trimWhitespace(val)));
                } else if (std.mem.eql(u8, key, "vendor_id") and !props.contains(.vendor_id)) {
                    props.put(.vendor_id, try gpa.dupe(u8, trimWhitespace(val)));
                } else if (std.mem.eql(u8, key, "microcode") and !props.contains(.microcode)) {
                    props.put(.microcode, try gpa.dupe(u8, trimWhitespace(val)));
                } else if (std.mem.eql(u8, key, "cpu cores") and !props.contains(.cpu_cores)) {
                    props.put(.cpu_cores, try gpa.dupe(u8, trimWhitespace(val)));
                } else if (std.mem.eql(u8, key, "flags") and vendor == .intel) {
                    if (!props.contains(.intel_epp) and std.mem.find(u8, val, "hwp_epp") != null) {
                        props.put(.intel_epp, try gpa.alloc(u8, 0));
                    }
                    if (!props.contains(.intel_epb) and std.mem.find(u8, val, "epb") != null) {
                        props.put(.intel_epb, try gpa.alloc(u8, 0));
                    }
                }
            }
        }
        const cpu_cores = if (props.get(.cpu_cores)) |v|
            std.fmt.parseInt(u32, v, 10) catch 0
        else
            null;
        return ProcInfo{
            .model_name = props.get(.model_name),
            .vendor_id = props.get(.vendor_id),
            .microcode = props.get(.microcode),
            .cpu_cores = cpu_cores,
            .intel_epp = props.contains(.intel_epp),
            .intel_epb = props.contains(.intel_epb),
        };
    }

    pub fn print(self: *const Self) void {
        std.debug.print(
            \\Model: {s}
            \\Vendor ID: {s}
            \\Microcode: {s}
            \\Cpu cores: {}
            \\
        , .{
            self.model_name orelse "N/A",
            self.vendor_id orelse "N/A",
            self.microcode orelse "N/A",
            self.cpu_cores orelse 0,
        });
    }

    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        if (self.model_name) |v| {
            gpa.free(v);
        }
        if (self.vendor_id) |v| {
            gpa.free(v);
        }
        if (self.microcode) |v| {
            gpa.free(v);
        }
    }
};

fn trimWhitespace(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

const testing = std.testing;
test "procinfo" {
    var procinfo = try ProcInfo.parse(testing.allocator, testing.io, .intel);
    defer procinfo.deinit(testing.allocator);
    std.debug.print("{any}\n", .{procinfo});
    procinfo.print();
}
