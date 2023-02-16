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

/// adapted from https://github.com/tomhoule/zig-diff/blob/68066d2845df6b64acf554b0d3ea235d4b09b5e0/src/main.zig#L81
pub fn formatChunk(chunk: lib.Chunk, writer: anytype) !void {
    switch (chunk) {
        .equal => |s| try writer.writeAll(s),
        .delete => |s| try writer.print("\x1b[41m{s}\x1b[0m", .{s}),
        .insert => |s| try writer.print("\x1b[42m{s}\x1b[0m", .{s}),
    }
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
        try formatChunk(chunk, stdout);
    }
}
