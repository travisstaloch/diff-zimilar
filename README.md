# diff-zimilar

a port of [dtolnay/dissimilar](https://github.com/dtolnay/dissimilar/) text diffing library to [zig](https://ziglang.org/). includes semantic cleanups.  based on google's diff match patch. 

# goals

* reduced memory footprint, limited allocations
* fast diffing, maybe for use in [zls](https://github.com/zigtools/zls)

# tools
### diffit
a simple diffing utility that can be run from the command line:
```console
$ zig build run -- <file_a> <file_b>
```
```console
$ zig build && zig-out/bin/diffit <file_a> <file_b>
```
this shows ansi colored diffs.

### benchmark
```console
$ zig run -lc -OReleaseFast src/bench.zig -- <file_a> <file_b> <iterations>
```
```console
$ zig  run -lc -OReleaseFast src/bench.zig -- /tmp/dissimilar/benches/document1.txt /tmp/dissimilar/benches/document2.txt 10
took 1.363s for 10 diffs
```

# usage
```zig
test {
    const diff = @import("lib.zig");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const aalloc = arena.allocator();
    // 'catch return' just allows test to pass
    const file_a = std.fs.cwd().openFile("/path/to/file_a", .{}) catch return; 
    const file_b = std.fs.cwd().openFile("/path/to/file_b", .{}) catch return;
    const doc_a = try file_a.readToEndAlloc(aalloc, std.math.maxInt(u32));
    const doc_b = try file_b.readToEndAlloc(aalloc, std.math.maxInt(u32));
    var chunks = try diff.diff(aalloc, doc_a, doc_b);
    defer chunks.deinit(aalloc);
}
```

# references
* inspired by [tomhoule/zig-diff](https://github.com/tomhoule/zig-diff/)
* ported from [dtolnay/dissimilar](https://github.com/dtolnay/dissimilar/)
* [google diff match patch](https://github.com/google/diff-match-patch)
* [Myers' diff algorithm](https://neil.fraser.name/writing/diff/myers.pdf)
* [semantic cleanups](https://neil.fraser.name/writing/diff/)
