//! $ zig  run -lc -OReleaseFast src/bench.zig -- /tmp/dissimilar/benches/document1.txt /tmp/dissimilar/benches/document2.txt 10
//! > took 1.363s for 10 diffs

const std = @import("std");
const lib = @import("lib.zig");

pub const std_options = struct {
    pub const log_level = .err;
};

fn bench(allocator: std.mem.Allocator, a: []const u8, b: []const u8, n: usize) !void {
    // var arena = std.heap.ArenaAllocator.init(allocator);
    // defer arena.deinit();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // _ = arena.reset(.free_all);
        var chunks = try lib.diff(allocator, a, b);
        chunks.deinit(allocator);
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var args = try std.process.argsWithAllocator(arena.allocator());
    _ = args.next();
    const filename_a = args.next() orelse return error.MissingArg;
    const filename_b = args.next() orelse return error.MissingArg;
    const file_a = try std.fs.cwd().openFile(filename_a, .{});
    const file_b = try std.fs.cwd().openFile(filename_b, .{});
    const doc_a = try file_a.readToEndAlloc(arena.allocator(), std.math.maxInt(u32));
    const doc_b = try file_b.readToEndAlloc(arena.allocator(), std.math.maxInt(u32));
    const n_str = args.next() orelse "10";
    const n = try std.fmt.parseUnsigned(usize, n_str, 10);
    var timer = try std.time.Timer.start();
    try bench(std.heap.c_allocator, doc_a, doc_b, n);
    const time = timer.lap();
    std.debug.print("took {} for {} diffs\n", .{ std.fmt.fmtDuration(time), n });
}
