const std = @import("std");
const mem = std.mem;
const panicf = std.debug.panic;

pub const std_options = struct {
    pub const log_level = std.meta.stringToEnum(
        std.log.Level,
        @tagName(@import("build_options").log_level),
    ).?;
};

const range = @import("range.zig");
pub const Range = range.Range;

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
        std.log.debug("growLeft({}, {})", .{ d.*, increment });
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
        // try writer.print(
        //     "{s} {s}({})-{any}",
        //     .{ prefix, d.first(), d.first().doc.len, d.first().doc },
        // );
        try writer.print("{s} {s}", .{ prefix, d.text() });
    }
};

pub fn equal(s: []const u8) Diff {
    return Diff.init(.equal, .{ Range.init(s), Range.init(s) });
}
pub fn delete(s: []const u8) Diff {
    return Diff.init(.delete, Range.init(s));
}
pub fn insert(s: []const u8) Diff {
    return Diff.init(.insert, Range.init(s));
}

pub const Chunk = union(DiffType) {
    equal: []const u8,
    delete: []const u8,
    insert: []const u8,
};

pub const DiffList = std.ArrayListUnmanaged(Diff);

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

// Determine the length of the common prefix of two strings.
pub fn commonPrefix(text1: Range, text2: Range) usize {
    for (text1.doc) |b1, i| {
        if (b1 != text2.doc[i]) return i;
    }
    return @min(text1.doc.len, text2.doc.len);
}

// Determine the length of the common suffix of two strings.
pub fn commonSuffix(text1: Range, text2: Range) usize {
    const max = @min(text1.doc.len, text2.doc.len);
    var i: usize = 1;
    const t1 = text1.doc;
    const t2 = text2.doc;
    std.log.debug("commonSuffix '{}' '{}' max {}", .{ text1, text2, max });
    while (i - 1 < max) : (i += 1) {
        std.log.debug("  '{c}' '{c}'", .{ t1[text1.doc.len - i], t2[text2.doc.len - i] });
        if (t1[text1.doc.len - i] != t2[text2.doc.len - i])
            return i - 1;
    }
    return max;
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
        text1 = text1.trimLeft(text1.doc.len - text2.doc.len);
    } else if (text1.doc.len < text2.doc.len) {
        text2 = text2.trimRight(text1.doc.len);
    }
    std.log.debug("commonOverlap() text1 {} text2 {}", .{ text1, text2 });
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
        const pattern = text1.trimLeft(text1.doc.len - length);
        const found = text2.find(pattern) orelse return best;
        length += found;
        if (found == 0 or
            text1.trimLeft(text1.doc.len - length)
            .eql(text2.trimRight(length)))
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
            solution.text1.trimLeft(solution.text1.doc.len),
            solution.text2.trimLeft(solution.text2.doc.len),
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
                    if (text_insert.isEmpty()) {
                        text_insert = text;
                    } else {
                        text_insert.doc.len += text.doc.len;
                    }
                },
                .delete => |text| {
                    count_delete += 1;
                    if (text_delete.isEmpty()) {
                        text_delete = text;
                    } else {
                        text_delete.doc.len += text.doc.len;
                    }
                },
                .equal => |texts| {
                    const text = texts[0];
                    const count_both = count_delete + count_insert;
                    std.log.debug(".equal {} count_both {}", .{ text, count_both });
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
                                        else => panicf("previous diff should have been an equality", .{}),
                                    }
                                } else {
                                    try diffs.insert(
                                        allocator,
                                        pointer,
                                        Diff.init(.equal, .{
                                            text_delete.trimRight(common_length),
                                            text_insert.trimRight(common_length),
                                        }),
                                    );
                                    pointer += 1;
                                }
                                text_insert = text_insert.trimLeft(common_length);
                                text_delete = text_delete.trimLeft(common_length);
                            }

                            // Factor out any common suffix.
                            const common_length2 = commonSuffix(text_insert, text_delete);
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
                            std.log.debug("prev equal {}", .{prev});
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
        if (diffs.items[diffs.items.len - 1].text().isEmpty()) {
            _ = diffs.pop(); // Remove the dummy entry at the end.
        }

        // Second pass: look for single edits surrounded on both sides by equalities
        // which can be shifted sideways to eliminate an equality.
        // e.g: A<ins>BA</ins>C -> <ins>AB</ins>AC
        var changes = false;
        var pointer2: usize = 1;
        // Intentionally ignore the first and last element (don't need checking).
        // while const Some(&next_diff) = diffs.get(pointer2 + 1) {
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
                if (best_next_equal[0].isEmpty()) {
                    _ = diffs.orderedRemove(pointer + 1);
                } else {
                    diffs.items[pointer + 1] =
                        Diff.init(.equal, .{ best_next_equal[0], best_next_equal[1] });
                }
                diffs.items[pointer] = best_edit;
                if (best_prev_equal[0].isEmpty()) {
                    _ = diffs.orderedRemove(pointer - 1);
                    pointer -= 1;
                } else {
                    diffs.items[pointer - 1] =
                        Diff.init(.equal, .{ best_prev_equal[0], best_prev_equal[1] });
                }
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
