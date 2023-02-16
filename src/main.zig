//! $ zig build && zig-out/bin/diffit src/bench.zig src/main.zig

const std = @import("std");
const lib = @import("lib.zig");

pub const std_options = struct {
    pub const log_level = .err;
};

const Error = error{MissingArg};

fn usage(exepath: []const u8, merr: ?Error) Error!void {
    std.debug.print("usage: {s} <file_a> <file_b>\n", .{exepath});
    if (merr) |err| return err;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const aalloc = arena.allocator();
    var args = try std.process.argsWithAllocator(aalloc);
    const exepath = args.next() orelse unreachable;
    const filename_a = args.next() orelse return usage(exepath, error.MissingArg);
    const filename_b = args.next() orelse return usage(exepath, error.MissingArg);
    const file_a = try std.fs.cwd().openFile(filename_a, .{});
    const file_b = try std.fs.cwd().openFile(filename_b, .{});
    const doc_a = try file_a.readToEndAlloc(aalloc, std.math.maxInt(u32));
    const doc_b = try file_b.readToEndAlloc(aalloc, std.math.maxInt(u32));
    var chunks = try lib.diff(aalloc, doc_a, doc_b);
    const stdout = std.io.getStdOut().writer();
    for (chunks.items) |chunk| {
        try stdout.print("{}\n", .{chunk});
    }
}
