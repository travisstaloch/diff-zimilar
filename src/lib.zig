const std = @import("std");
const mem = std.mem;
const panicf = std.debug.panic;

pub const std_options = struct {
    pub const log_level = std.meta.stringToEnum(
        std.log.Level,
        @tagName(@import("build_options").log_level),
    ).?;
};

const rg = @import("range.zig");
pub const Range = rg.Range;
pub const range = rg.range;

pub const Error = mem.Allocator.Error;

pub const DiffType = std.meta.Tag(Diff);
pub const Diff = union(enum) {
    equal: [2]Range,
    delete: Range,
    insert: Range,

    pub fn init(
        comptime ty: DiffType,
        payload: std.meta.FieldType(Diff, ty),
    ) Diff {
        return @unionInit(Diff, @tagName(ty), payload);
    }

    pub fn text(d: Diff) Range {
        return switch (d) {
            .equal => |rs| rs[0],
            .delete => |rs| rs,
            .insert => |rs| rs,
        };
    }

    pub fn forEach(
        d: *Diff,
        increment: usize,
        f: *const fn (*Range, usize) void,
    ) void {
        switch (d.*) {
            .equal => |*rs| {
                f(&rs[0], increment);
                f(&rs[1], increment);
            },
            .insert => |*r| f(r, increment),
            .delete => |*r| f(r, increment),
        }
    }
    pub fn growLeft(d: *Diff, increment: usize) void {
        forEach(d, increment, struct {
            fn f(r: *Range, inc: usize) void {
                r.doc.ptr -= inc;
                r.doc.len += inc;
            }
        }.f);
    }

    pub fn growRight(d: *Diff, increment: usize) void {
        forEach(d, increment, struct {
            fn f(r: *Range, inc: usize) void {
                r.doc.len += inc;
            }
        }.f);
    }

    pub fn shiftLeft(d: *Diff, increment: usize) void {
        forEach(d, increment, struct {
            fn f(r: *Range, inc: usize) void {
                r.doc.ptr -= inc;
            }
        }.f);
    }

    pub fn shiftRight(d: *Diff, increment: usize) void {
        forEach(d, increment, struct {
            fn f(r: *Range, inc: usize) void {
                r.doc.ptr += inc;
            }
        }.f);
    }

    pub fn format(
        d: Diff,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const prefix = switch (d) {
            .equal => "=",
            .insert => "+",
            .delete => "-",
        };
        try writer.print("{s} {s}", .{ prefix, d.text() });
    }
};

pub const DiffList = std.ArrayListUnmanaged(Diff);

pub fn equal(s: []const u8) Diff {
    return Diff.init(.equal, .{ range(s), range(s) });
}
pub fn delete(s: []const u8) Diff {
    return Diff.init(.delete, range(s));
}
pub fn insert(s: []const u8) Diff {
    return Diff.init(.insert, range(s));
}

pub const Solution = struct {
    text1: Range,
    text2: Range,
    diffs: DiffList = .{},

    pub fn initEmpty() Solution {
        return .{ .text1 = Range.empty, .text2 = Range.empty };
    }

    pub fn deinit(s: *Solution, allocator: mem.Allocator) void {
        s.diffs.deinit(allocator);
        allocator.free(s.text1.doc);
        allocator.free(s.text2.doc);
    }
};

pub const Chunk = union(DiffType) {
    equal: []const u8,
    delete: []const u8,
    insert: []const u8,
};

/// The main api endpoint.
/// text1 and text2 are the inputs to be diffed.
/// returns a list of chunks which are slices of the input strings.
pub fn diff(
    allocator: mem.Allocator,
    text1: []const u8,
    text2: []const u8,
) !std.ArrayListUnmanaged(Chunk) {
    var solution = try diffMain(allocator, range(text1), range(text2));
    cleanupCharBoundary(allocator, &solution);
    try cleanupSemantic(allocator, &solution);
    try cleanupMerge(allocator, &solution);

    var chunks = std.ArrayListUnmanaged(Chunk){};
    var pos1: usize = 0;
    var pos2: usize = 0;
    for (solution.diffs.items) |d| {
        try chunks.append(allocator, switch (d) {
            .equal => |rs| blk: {
                const r = rs[0];
                const len = r.lenBytes();
                const chunk = Chunk{ .equal = text1[pos1 .. pos1 + len] };
                pos1 += len;
                pos2 += len;
                break :blk chunk;
            },
            .delete => |r| blk: {
                const len = r.lenBytes();
                const chunk = Chunk{ .delete = text1[pos1 .. pos1 + len] };
                pos1 += len;
                break :blk chunk;
            },
            .insert => |r| blk: {
                const len = r.lenBytes();
                const chunk = Chunk{ .insert = text2[pos2 .. pos2 + len] };
                pos2 += len;
                break :blk chunk;
            },
        });
    }
    return chunks;
}

pub fn diffMain(allocator: mem.Allocator, text1_: Range, text2_: Range) !Solution {
    var text1 = text1_;
    var text2 = text2_;
    std.log.debug("main() {} {}", .{ text1, text2 });

    // Trim off common prefix.
    const common_prefix_len = commonPrefix(text1, text2);
    const common_prefix = Diff.init(.equal, .{
        text1.substringTo(common_prefix_len),
        text2.substringTo(common_prefix_len),
    });
    text1 = text1.substringFrom(common_prefix_len);
    text2 = text2.substringFrom(common_prefix_len);

    // Trim off common suffix.
    const common_suffix_len = commonSuffix(text1, text2);
    const common_suffix = Diff.init(.equal, .{
        text1.substringFrom(text1.doc.len - common_suffix_len),
        text2.substringFrom(text2.doc.len - common_suffix_len),
    });
    text1 = text1.substringTo(text1.doc.len - common_suffix_len);
    text2 = text2.substringTo(text2.doc.len - common_suffix_len);

    // Compute the diff on the middle block.
    var solution = Solution{
        .text1 = text1_,
        .text2 = text2_,
        .diffs = try compute(allocator, text1, text2),
    };
    std.log.debug("main() computed diffs {any}", .{solution.diffs.items});

    // Restore the prefix and suffix.
    if (common_prefix_len > 0)
        try solution.diffs.insert(allocator, 0, common_prefix);

    if (common_suffix_len > 0)
        try solution.diffs.append(allocator, common_suffix);

    try cleanupMerge(allocator, &solution);

    return solution;
}

// Find the differences between two texts. Assumes that the texts do not have
// any common prefix or suffix.
pub fn compute(allocator: mem.Allocator, text1: Range, text2: Range) !DiffList {
    var diffs = DiffList{};

    const is_emptys_ = [2]bool{ text1.isEmpty(), text2.isEmpty() };
    const is_emptys: @Vector(2, bool) = is_emptys_;
    switch (@bitCast(u2, is_emptys)) {
        0b11 => return diffs,
        0b01 => {
            try diffs.append(allocator, Diff.init(.insert, text2));
            return diffs;
        },
        0b10 => {
            try diffs.append(allocator, Diff.init(.delete, text1));
            return diffs;
        },
        0b00 => {},
    }

    // Check for entire shorter text inside the longer text.
    if (text1.doc.len > text2.doc.len) {
        if (text1.find(text2)) |i| {
            try diffs.appendSlice(allocator, &.{
                Diff.init(.delete, text1.substringTo(i)),
                Diff.init(.equal, .{
                    text1.substring(i, i + text2.doc.len),
                    text2,
                }),
                Diff.init(.delete, text1.substringFrom(i + text2.doc.len)),
            });
            return diffs;
        }
    } else if (text2.find(text1)) |i| {
        try diffs.appendSlice(allocator, &.{
            Diff.init(.insert, text2.substringTo(i)),
            Diff.init(.equal, .{
                text1,
                text2.substring(i, i + text1.doc.len),
            }),
            Diff.init(.insert, text2.substringFrom(i + text1.doc.len)),
        });
        return diffs;
    }

    if (text1.doc.len == 1 or text2.doc.len == 1) {
        // Single character string.
        // After the previous check, the character can't be an equality.
        try diffs.appendSlice(allocator, &.{
            Diff.init(.delete, text1),
            Diff.init(.insert, text2),
        });
        return diffs;
    }

    return bisect(allocator, text1, text2);
}

// Find the 'middle snake' of a diff, split the problem in two and return the
// recursively constructed diff.
//
// See Myers 1986 paper: An O(ND) Difference Algorithm and Its Variations.
pub fn bisect(allocator: mem.Allocator, text1: Range, text2: Range) !DiffList {
    const max_d = (text1.doc.len + text2.doc.len + 1) / 2;
    const v_offset = max_d;
    const v_len = 2 * max_d;
    var v1 = try std.ArrayListUnmanaged(isize).initCapacity(allocator, v_len);
    defer v1.deinit(allocator);
    v1.items.len = v_len;
    // TODO - maybe faster to do these mem.set()s together?
    var v2 = try std.ArrayListUnmanaged(isize).initCapacity(allocator, v_len);
    defer v2.deinit(allocator);
    v2.items.len = v_len;
    @memset(v1.items, -1);
    @memset(v2.items, -1);
    v1.items[v_offset + 1] = 0;
    v2.items[v_offset + 1] = 0;
    const delta = @intCast(isize, text1.doc.len) - @intCast(isize, text2.doc.len);
    // If the total number of characters is odd, then the front path will
    // collide with the reverse path.
    const front = @mod(delta, 2) != 0;
    // Offsets for start and end of k loop.
    // Prevents mapping of space beyond the grid.
    var k1start: isize = 0;
    var k1end: isize = 0;
    var k2start: isize = 0;
    var k2end: isize = 0;
    var d: isize = 0;
    while (d < max_d) : (d += 1) {
        // Walk the front path one step.
        var k1 = -d + k1start;
        while (k1 <= d - k1end) {
            const k1_offset = @intCast(usize, (@intCast(isize, v_offset) + k1));
            var x1 = @intCast(usize, if (k1 == -d or (k1 != d and
                v1.items[k1_offset - 1] < v1.items[k1_offset + 1]))
                v1.items[k1_offset + 1]
            else
                v1.items[k1_offset - 1] + 1);
            var y1 = @intCast(usize, (@intCast(isize, x1) - k1));
            if (x1 < text1.doc.len and y1 < text2.doc.len) {
                const advance = commonPrefix(
                    text1.substringFrom(x1),
                    text2.substringFrom(y1),
                );
                x1 += advance;
                y1 += advance;
            }
            v1.items[k1_offset] = @intCast(isize, x1);
            if (x1 > text1.doc.len) {
                // Ran off the right of the graph.
                k1end += 2;
            } else if (y1 > text2.doc.len) {
                // Ran off the bottom of the graph.
                k1start += 2;
            } else if (front) {
                const k2_offset = @intCast(isize, v_offset) + delta - k1;
                if (k2_offset >= 0 and k2_offset < @intCast(isize, v_len) and
                    v2.items[@intCast(usize, k2_offset)] != -1)
                {
                    // Mirror x2 onto top-left coordinate system.
                    const x2 = @intCast(isize, text1.doc.len) -
                        v2.items[@intCast(usize, k2_offset)];
                    if (@intCast(isize, x1) >= x2) {
                        // Overlap detected.
                        std.log.debug(
                            "bisect() overlap detected 1 {} {} {} {}",
                            .{ text1, text2, x1, y1 },
                        );
                        return bisectSplit(allocator, text1, text2, x1, y1);
                    }
                }
            }
            k1 += 2;
        }

        // Walk the reverse path one step.
        var k2 = -d + k2start;
        while (k2 <= d - k2end) {
            const k2_offset = @intCast(usize, (@intCast(isize, v_offset) + k2));
            var x2 = @intCast(usize, if (k2 == -d or (k2 != d and
                v2.items[k2_offset - 1] < v2.items[k2_offset + 1]))
                v2.items[k2_offset + 1]
            else
                v2.items[k2_offset - 1] + 1);
            var y2 = @intCast(usize, (@intCast(isize, x2) - k2));
            if (x2 < text1.doc.len and y2 < text2.doc.len) {
                const advance = commonSuffix(
                    text1.substringTo(text1.doc.len - x2),
                    text2.substringTo(text2.doc.len - y2),
                );
                x2 += advance;
                y2 += advance;
            }
            v2.items[k2_offset] = @intCast(isize, x2);
            if (x2 > text1.doc.len) {
                // Ran off the left of the graph.
                k2end += 2;
            } else if (y2 > text2.doc.len) {
                // Ran off the top of the graph.
                k2start += 2;
            } else if (!front) {
                const k1_offset = @intCast(isize, v_offset) + delta - k2;
                if (k1_offset >= 0 and k1_offset < @intCast(isize, v_len) and
                    v1.items[@intCast(usize, k1_offset)] != -1)
                {
                    const x1 = @intCast(usize, v1.items[@intCast(usize, k1_offset)]);
                    const y1 = v_offset + x1 - @intCast(usize, k1_offset);
                    // Mirror x2 onto top-left coordinate system.
                    x2 = text1.doc.len - x2;
                    if (x1 >= x2) {
                        // Overlap detected.
                        std.log.debug(
                            "bisect() overlap detected 2 {} {} {} {}",
                            .{ text1, text2, x1, y1 },
                        );
                        return bisectSplit(allocator, text1, text2, x1, y1);
                    }
                }
            }
            k2 += 2;
        }
    }
    // Number of diffs equals number of characters, no commonality at all.
    var result = DiffList{};
    std.log.debug("bisect() text1='{}' text2='{}'", .{ text1, text2 });
    try result.appendSlice(allocator, &.{
        Diff.init(.delete, text1),
        Diff.init(.insert, text2),
    });
    return result;
}

// Given the location of the 'middle snake', split the diff in two parts and
// recurse.
pub fn bisectSplit(
    allocator: mem.Allocator,
    text1: Range,
    text2: Range,
    x: usize,
    y: usize,
) Error!DiffList {
    const text1s = text1.splitAt(x);
    const text1a = text1s[0];
    const text1b = text1s[1];
    const text2s = text2.splitAt(y);
    const text2a = text2s[0];
    const text2b = text2s[1];

    // Compute both diffs serially.
    var solution = try diffMain(allocator, text1a, text2a);
    var solution2 = try diffMain(allocator, text1b, text2b);
    defer solution2.diffs.deinit(allocator);
    try solution.diffs.appendSlice(allocator, solution2.diffs.items);
    return solution.diffs;
}

// Determine the length of the common prefix of two strings.
pub fn commonPrefix(text1: Range, text2: Range) usize {
    const min_len = @min(text1.doc.len, text2.doc.len);
    var i: usize = 0;
    while (i < min_len) : (i += 1)
        if (text1.doc[i] != text2.doc[i]) return i;
    return min_len;
}

// Determine the length of the common suffix of two strings.
pub fn commonSuffix(text1: Range, text2: Range) usize {
    const min_len = @min(text1.doc.len, text2.doc.len);
    var i: usize = 1;
    while (i <= min_len) : (i += 1)
        if (text1.doc[text1.doc.len - i] != text2.doc[text2.doc.len - i])
            return i - 1;
    return min_len;
}

// Determine if the suffix of one string is the prefix of another.
//
// Returns the number of characters common to the end of the first string and
// the start of the second string.
pub fn commonOverlap(text1_: Range, text2_: Range) usize {
    // Eliminate the null case.
    var text1 = text1_;
    var text2 = text2_;
    if (text1.isEmpty() or text2.isEmpty()) {
        return 0;
    }
    // Truncate the longer string.
    if (text1.doc.len > text2.doc.len) {
        text1 = text1.substringFrom(text1.doc.len - text2.doc.len);
    } else if (text1.doc.len < text2.doc.len) {
        text2 = text2.substringTo(text1.doc.len);
    }
    // Quick check for the worst case.
    if (text1.eql(text2)) {
        return text1.doc.len;
    }

    // Start by looking for a single character match
    // and increase length until no match is found.
    // Performance analysis: https://neil.fraser.name/news/2010/11/04/
    var best: usize = 0;
    var length: usize = 1;
    while (true) {
        const pattern = text1.substringFrom(text1.doc.len - length);
        const found = text2.find(pattern) orelse return best;
        length += found;
        if (found == 0 or
            text1.substringFrom(text1.doc.len - length)
            .eql(text2.substringTo(length)))
        {
            best = length;
            length += 1;
        }
    }
}

// Reorder and merge like edit sections. Merge equalities. Any edit section can
// move as long as it doesn't cross an equality.
pub fn cleanupMerge(allocator: mem.Allocator, solution: *Solution) !void {
    const diffs = &solution.diffs;
    while (diffs.items.len != 0) {
        std.log.debug(
            "cleanupMerge() text1='{s}' text2='{s}' diffs {any}",
            .{ solution.text1, solution.text2, diffs.items },
        );
        try diffs.append(allocator, Diff.init(.equal, .{
            solution.text1.substringFrom(solution.text1.doc.len),
            solution.text2.substringFrom(solution.text2.doc.len),
        })); // Add a dummy entry at the end.
        var pointer: usize = 0;
        var count_delete: usize = 0;
        var count_insert: usize = 0;
        var text_delete = Range.empty;
        var text_insert = Range.empty;
        while (pointer < diffs.items.len) {
            const this_diff = diffs.items[pointer];
            std.log.debug("cleanupMerge() {} '{}' ", .{ pointer, this_diff });
            switch (this_diff) {
                .insert => |text| {
                    count_insert += 1;
                    if (text_insert.isEmpty())
                        text_insert = text
                    else
                        text_insert.doc.len += text.doc.len;
                },
                .delete => |text| {
                    count_delete += 1;
                    if (text_delete.isEmpty())
                        text_delete = text
                    else
                        text_delete.doc.len += text.doc.len;
                },
                .equal => |texts| {
                    const text = texts[0];
                    const count_both = count_delete + count_insert;
                    if (count_both > 1) {
                        const both_types = count_delete != 0 and
                            count_insert != 0;
                        // Delete the offending records.
                        try diffs.replaceRange(
                            allocator,
                            pointer - count_both,
                            count_both,
                            &.{},
                        );
                        pointer -= count_both;
                        if (both_types) {
                            // Factor out any common prefix.
                            const common_length =
                                commonPrefix(text_insert, text_delete);
                            std.log.debug(
                                "1 text_insert {} text_delete {} common_length {}",
                                .{ text_insert, text_delete, common_length },
                            );
                            if (common_length != 0) {
                                if (pointer > 0) {
                                    const prev = &diffs.items[pointer - 1];
                                    switch (prev.*) {
                                        .equal => {
                                            prev.equal[0].doc.len += common_length;
                                            prev.equal[1].doc.len += common_length;
                                        },
                                        else => panicf(
                                            "previous diff should have been an equality",
                                            .{},
                                        ),
                                    }
                                } else {
                                    try diffs.insert(
                                        allocator,
                                        pointer,
                                        Diff.init(.equal, .{
                                            text_delete.substringTo(common_length),
                                            text_insert.substringTo(common_length),
                                        }),
                                    );
                                    pointer += 1;
                                }
                                text_insert =
                                    text_insert.substringFrom(common_length);
                                text_delete =
                                    text_delete.substringFrom(common_length);
                            }

                            // Factor out any common suffix.
                            const common_length2 =
                                commonSuffix(text_insert, text_delete);
                            std.log.debug(
                                "2 text_insert {} text_delete {} common_length2 {}",
                                .{ text_insert, text_delete, common_length2 },
                            );
                            if (common_length2 != 0) {
                                diffs.items[pointer].growLeft(common_length2);
                                text_insert.doc.len -= common_length2;
                                text_delete.doc.len -= common_length2;
                            }
                        }
                        // Insert the merged records.
                        if (!text_delete.isEmpty()) {
                            try diffs.insert(
                                allocator,
                                pointer,
                                Diff.init(.delete, text_delete),
                            );
                            pointer += 1;
                        }
                        if (!text_insert.isEmpty()) {
                            try diffs.insert(
                                allocator,
                                pointer,
                                Diff.init(.insert, text_insert),
                            );
                            pointer += 1;
                        }
                    } else if (pointer > 0) {
                        var prev = &diffs.items[pointer - 1];
                        if (prev.* == .equal) {
                            // Merge this equality with the previous one.
                            prev.equal[0].doc.len += text.doc.len;
                            prev.equal[1].doc.len += text.doc.len;
                            _ = diffs.orderedRemove(pointer);
                            pointer -= 1;
                        }
                    }
                    count_insert = 0;
                    count_delete = 0;
                    text_delete = Range.empty;
                    text_insert = Range.empty;
                },
            }
            pointer += 1;
        }
        if (diffs.items[diffs.items.len - 1].text().isEmpty())
            _ = diffs.pop(); // Remove the dummy entry at the end.

        // Second pass: look for single edits surrounded on both sides by equalities
        // which can be shifted sideways to eliminate an equality.
        // e.g: A<ins>BA</ins>C -> <ins>AB</ins>AC
        var changes = false;
        var pointer2: usize = 1;
        // Intentionally ignore the first and last element (don't need checking).
        while (pointer2 + 1 < diffs.items.len) {
            const next_diff = diffs.items[pointer2 + 1];
            const prev_diff = diffs.items[pointer2 - 1];
            const this_diff = diffs.items[pointer2];
            if (prev_diff == .equal and next_diff == .equal) {
                // This is a single edit surrounded by equalities.
                const prev_diff_range = prev_diff.equal[0];
                const next_diff_range = next_diff.equal[0];
                if (this_diff.text().endsWith(prev_diff_range)) {
                    // Shift the edit over the previous equality.
                    diffs.items[pointer2].shiftLeft(prev_diff_range.doc.len);
                    diffs.items[pointer2 + 1].growLeft(prev_diff_range.doc.len);
                    _ = diffs.orderedRemove(pointer2 - 1); // Delete prev_diff.
                    changes = true;
                } else if (this_diff.text().startsWith(next_diff_range)) {
                    // Shift the edit over the next equality.
                    diffs.items[pointer2 - 1].growRight(next_diff_range.doc.len);
                    diffs.items[pointer2].shiftRight(next_diff_range.doc.len);
                    _ = diffs.orderedRemove(pointer2 + 1); // Delete next_diff.
                    changes = true;
                }
            }
            pointer2 += 1;
        }
        // If shifts were made, the diff needs reordering and another shift sweep.
        if (!changes) {
            return;
        }
    }
}
fn isSegmentationBoundary(doc: []const u8, pos: [*]const u8) bool {
    // FIXME: use unicode-segmentation crate?
    _ = doc;
    _ = pos;
    return true;
}

fn boundaryDown(doc: []const u8, pos: [*]const u8) usize {
    var adjust: usize = 0;
    while (!isSegmentationBoundary(doc, pos - adjust))
        adjust += 1;
    return adjust;
}

fn boundaryUp(doc: []const u8, ptr: [*]const u8) usize {
    var adjust: usize = 0;
    while (!isSegmentationBoundary(doc, ptr + adjust))
        adjust += 1;

    return adjust;
}

fn skipOverlap(prev: Range, r: *Range) void {
    const prev_end = @intFromPtr(prev.doc.ptr + prev.doc.len);
    const rdoc_ptr = @intFromPtr(r.doc.ptr);
    if (prev_end > rdoc_ptr) {
        const delta = @min(prev_end - rdoc_ptr, r.doc.len);
        r.doc.ptr += delta;
        r.doc.len -= delta;
    }
}

fn cleanupCharBoundary(allocator: mem.Allocator, solution: *Solution) void {
    var read: usize = 0;
    var retain: usize = 0;
    var last_delete = Range.empty;
    var last_insert = Range.empty;
    while (read < solution.diffs.items.len) {
        const d = &solution.diffs.items[read];
        read += 1;
        switch (d.*) {
            .equal => {
                const range1 = &d.equal[0];
                const range2 = &d.equal[1];
                const adjust = boundaryUp(range1.doc, range1.doc.ptr);
                // If the whole range is sub-character, skip it.
                if (range1.doc.len <= adjust) continue;

                range1.doc.ptr += adjust;
                range1.doc.len -= adjust;
                range2.doc.ptr += adjust;
                range2.doc.len -= adjust;
                const adjust2 = boundaryDown(range1.doc, range1.doc.ptr + range1.doc.len);
                range1.doc.len -= adjust2;
                range2.doc.len -= adjust2;
                last_delete = Range.empty;
                last_insert = Range.empty;
            },
            .delete => {
                const r = &d.delete;
                skipOverlap(last_delete, r);
                if (r.doc.len == 0) continue;

                const adjust = boundaryDown(r.doc, r.doc.ptr);
                r.doc.ptr -= adjust;
                r.doc.len += adjust;
                r.doc.len += boundaryUp(r.doc, r.doc.ptr + r.doc.len);
                last_delete = r.*;
            },
            .insert => {
                const r = &d.insert;
                skipOverlap(last_insert, r);
                if (r.doc.len == 0) continue;

                const adjust = boundaryDown(r.doc, r.doc.ptr);
                r.doc.ptr -= adjust;
                r.doc.len += adjust;
                r.doc.len += boundaryUp(r.doc, r.doc.ptr + r.doc.len);
                last_insert = r.*;
            },
        }
        solution.diffs.items[retain] = d.*;
        retain += 1;
    }

    solution.diffs.shrinkAndFree(allocator, retain);
}

// Reduce the number of edits by eliminating semantically trivial equalities.
pub fn cleanupSemantic(allocator: mem.Allocator, solution: *Solution) !void {
    var diffs = &solution.diffs;
    if (diffs.items.len == 0) return;

    var changes = false;
    var equalities = std.ArrayListUnmanaged(usize){};
    defer equalities.deinit(allocator);

    var last_equality: ?[2]Range = null; // Always equal to equalities.peek().text
    var pointer: usize = 0;
    // Number of characters that changed prior to the equality.
    var len_insertions1: usize = 0;
    var len_deletions1: usize = 0;
    // Number of characters that changed after the equality.
    var len_insertions2: usize = 0;
    var len_deletions2: usize = 0;
    while (pointer < diffs.items.len) {
        const this_diff = diffs.items[pointer];
        switch (this_diff) {
            .equal => |texts| {
                const text1 = texts[0];
                const text2 = texts[1];
                try equalities.append(allocator, pointer);
                len_insertions1 = len_insertions2;
                len_deletions1 = len_deletions2;
                len_insertions2 = 0;
                len_deletions2 = 0;
                last_equality = .{ text1, text2 };
                pointer += 1;
                continue;
            },
            .delete => |text| len_deletions2 += text.doc.len,
            .insert => |text| len_insertions2 += text.doc.len,
        }
        // Eliminate an equality that is smaller or equal to the edits on both
        // sides of it.
        const x = if (last_equality) |leq|
            leq[0].doc.len <= @max(len_insertions1, len_deletions1) and
                leq[0].doc.len <= @max(len_insertions2, len_deletions2)
        else
            false;

        if (x) {
            // Jump back to offending equality.
            pointer = equalities.pop();

            // Replace equality with a delete.
            diffs.items[pointer] = Diff.init(.delete, last_equality.?[0]);
            // Insert a corresponding insert.
            try diffs.insert(
                allocator,
                pointer + 1,
                Diff.init(.insert, last_equality.?[1]),
            );

            len_insertions1 = 0; // Reset the counters.
            len_insertions2 = 0;
            len_deletions1 = 0;
            len_deletions2 = 0;
            last_equality = null;
            changes = true;

            // Throw away the previous equality (it needs to be reevaluated).
            _ = equalities.popOrNull();

            if (equalities.getLastOrNull()) |back| {
                // There is a safe equality we can fall back to.
                pointer = back;
            } else {
                // There are no previous equalities, jump back to the start.
                pointer = 0;
                continue;
            }
        }
        pointer += 1;
    }

    // Normalize the diff.
    if (changes) try cleanupMerge(allocator, solution);

    try cleanupSemanticLossless(allocator, solution);
    diffs = &solution.diffs;

    // Find any overlaps between deletions and insertions.
    // e.g: <del>abcxxx</del><ins>xxxdef</ins>
    //   -> <del>abc</del>xxx<ins>def</ins>
    // e.g: <del>xxxabc</del><ins>defxxx</ins>
    //   -> <ins>def</ins>xxx<del>abc</del>
    // Only extract an overlap if it is as big as the edit ahead or behind it.
    var pointer2: usize = 1;
    while (pointer2 < diffs.items.len) {
        const this_diff = diffs.items[pointer2];
        const prev_diff = diffs.items[pointer2 - 1];
        if (prev_diff == .delete and this_diff == .insert) {
            const deletion = prev_diff.delete;
            const insertion = this_diff.insert;
            const overlap_len1 = commonOverlap(deletion, insertion);
            const overlap_len2 = commonOverlap(insertion, deletion);
            const overlap_min = @min(deletion.doc.len, insertion.doc.len);
            if (overlap_len1 >= overlap_len2 and 2 * overlap_len1 >= overlap_min) {
                // Overlap found. Insert an equality and trim the surrounding edits.
                try diffs.insert(
                    allocator,
                    pointer2,
                    Diff.init(.equal, .{
                        deletion.substring(
                            deletion.doc.len - overlap_len1,
                            deletion.doc.len,
                        ),
                        insertion.substringTo(overlap_len1),
                    }),
                );
                diffs.items[pointer2 - 1] = Diff.init(
                    .delete,
                    deletion.substringTo(deletion.doc.len - overlap_len1),
                );
                diffs.items[pointer2 + 1] =
                    Diff.init(.insert, insertion.substringFrom(overlap_len1));
            } else if (overlap_len1 < overlap_len2 and
                2 * overlap_len2 >= overlap_min)
            {
                // Reverse overlap found.
                // Insert an equality and swap and trim the surrounding edits.
                try diffs.insert(
                    allocator,
                    pointer2,
                    Diff.init(.equal, .{
                        deletion.substringTo(overlap_len2),
                        insertion.substring(
                            insertion.doc.len - overlap_len2,
                            insertion.doc.len,
                        ),
                    }),
                );
                diffs.items[pointer2 - 1] = Diff.init(
                    .insert,
                    insertion.substringTo(insertion.doc.len - overlap_len2),
                );
                diffs.items[pointer2 + 1] = Diff.init(
                    .delete,
                    deletion.substringFrom(overlap_len2),
                );
            }
            pointer2 += 1;
        }
        pointer2 += 1;
    }
}

// Look for single edits surrounded on both sides by equalities which can be
// shifted sideways to align the edit to a word boundary.
//
// e.g: The c<ins>at c</ins>ame. -> The <ins>cat </ins>came.
pub fn cleanupSemanticLossless(_: mem.Allocator, solution: *Solution) !void {
    const diffs = &solution.diffs;
    var pointer: usize = 1;
    while (pointer + 1 < diffs.items.len) {
        var next_diff = diffs.items[pointer + 1];
        var prev_diff = diffs.items[pointer - 1];
        if (prev_diff == .equal and next_diff == .equal) {
            const prev_equals = prev_diff.equal;
            const next_equals = next_diff.equal;
            var prev_equal1 = prev_equals[0];
            var prev_equal2 = prev_equals[1];
            var next_equal1 = next_equals[0];
            var next_equal2 = next_equals[1];
            // This is a single edit surrounded by equalities.
            var edit = diffs.items[pointer];

            // First, shift the edit as far left as possible.
            const common_offset = commonSuffix(prev_equal1, edit.text());
            const original_prev_len = prev_equal1.doc.len;

            prev_equal1.doc.len -= common_offset;
            prev_equal2.doc.len -= common_offset;
            edit.shiftLeft(common_offset);
            next_equal1.doc.ptr -= common_offset;
            next_equal1.doc.len += common_offset;
            next_equal2.doc.ptr -= common_offset;
            next_equal2.doc.len += common_offset;

            // Second, step character by character right, looking for the best fit.
            var best_prev_equal: [2]Range = .{ prev_equal1, prev_equal2 };
            var best_edit = edit;
            var best_next_equal: [2]Range = .{ next_equal1, next_equal2 };
            var best_score = cleanupSemanticScore(prev_equal1, edit.text()) +
                cleanupSemanticScore(edit.text(), next_equal1);
            while (!edit.text().isEmpty() and
                !next_equal1.isEmpty() and
                edit.text().doc[0] == next_equal1.doc[0])
            {
                prev_equal1.doc.len += 1;
                prev_equal2.doc.len += 1;
                edit.shiftRight(1);
                next_equal1.doc.ptr += 1;
                next_equal1.doc.len -= 1;
                next_equal2.doc.ptr += 1;
                next_equal2.doc.len -= 1;
                const score = cleanupSemanticScore(prev_equal1, edit.text()) +
                    cleanupSemanticScore(edit.text(), next_equal1);
                // The >= encourages trailing rather than leading whitespace on edits.
                if (score >= best_score) {
                    best_score = score;
                    best_prev_equal = .{ prev_equal1, prev_equal2 };
                    best_edit = edit;
                    best_next_equal = .{ next_equal1, next_equal2 };
                }
            }

            if (original_prev_len != best_prev_equal[0].doc.len) {
                // We have an improvement, save it back to the diff.
                if (best_next_equal[0].isEmpty())
                    _ = diffs.orderedRemove(pointer + 1)
                else
                    diffs.items[pointer + 1] =
                        Diff.init(.equal, .{
                        best_next_equal[0],
                        best_next_equal[1],
                    });

                diffs.items[pointer] = best_edit;
                if (best_prev_equal[0].isEmpty()) {
                    _ = diffs.orderedRemove(pointer - 1);
                    pointer -= 1;
                } else diffs.items[pointer - 1] =
                    Diff.init(.equal, .{
                    best_prev_equal[0],
                    best_prev_equal[1],
                });
            }
        }
        pointer += 1;
    }
}

// Given two strings, compute a score representing whether the internal boundary
// falls on logical boundaries.
//
// Scores range from 6 (best) to 0 (worst).
fn cleanupSemanticScore(one: Range, two: Range) usize {
    if (one.isEmpty() or two.isEmpty()) {
        // Edges are the best.
        return 6;
    }

    // Each port of this function behaves slightly differently due to subtle
    // differences in each language's definition of things like 'whitespace'.
    // Since this function's purpose is largely cosmetic, the choice has been
    // made to use each language's native features rather than force total
    // conformity.
    const char1 = one.doc[one.doc.len - 1];
    const char2 = two.doc[0];
    const non_alphanumeric1 = !std.ascii.isAlphanumeric(char1);
    const non_alphanumeric2 = !std.ascii.isAlphanumeric(char2);
    const whitespace1 = non_alphanumeric1 and std.ascii.isWhitespace(char1);
    const whitespace2 = non_alphanumeric2 and std.ascii.isWhitespace(char2);
    const line_break1 = whitespace1 and std.ascii.isControl(char1);
    const line_break2 = whitespace2 and std.ascii.isControl(char2);
    const blank_line1 =
        line_break1 and (mem.endsWith(u8, one.doc, "\n\n") or
        mem.endsWith(u8, one.doc, "\n\r\n"));
    const blank_line2 =
        line_break2 and (mem.startsWith(u8, two.doc, "\n\n") or
        mem.startsWith(u8, two.doc, "\r\n\r\n"));

    return if (blank_line1 or blank_line2)
        // Five points for blank lines.
        5
    else if (line_break1 or line_break2)
        // Four points for line breaks.
        4
    else if (non_alphanumeric1 and !whitespace1 and whitespace2)
        // Three points for end of sentences.
        3
    else if (whitespace1 or whitespace2)
        // Two points for whitespace.
        2
    else if (non_alphanumeric1 or non_alphanumeric2)
        // One point for non-alphanumeric.
        1
    else
        0;
}
