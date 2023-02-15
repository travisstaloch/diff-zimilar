const std = @import("std");
const mem = std.mem;
const lib = @import("lib.zig");
const commonPrefix = lib.commonPrefix;
const commonSuffix = lib.commonSuffix;
const commonOverlap = lib.commonOverlap;
const cleanupMerge = lib.cleanupMerge;
const cleanupSemanticLossless = lib.cleanupSemanticLossless;
const cleanupSemantic = lib.cleanupSemantic;
const bisect = lib.bisect;
const main = lib.main;
const testing = std.testing;
const Range = lib.Range;
const Diff = lib.Diff;
const DiffList = lib.DiffList;
const Solution = lib.Solution;
const Chunk = lib.Chunk;
const equal = lib.equal;
const delete = lib.delete;
const insert = lib.insert;
const talloc = testing.allocator;

fn range(s: []const u8) Range {
    return Range.init(s);
}

fn expectEqual(
    expected: anytype,
    actual: @TypeOf(expected),
    test_name: []const u8,
) !void {
    testing.expectEqual(expected, actual) catch |e| {
        std.log.err("{s}", .{test_name});
        return e;
    };
}

test commonPrefix {
    try expectEqual(
        @as(usize, 0),
        commonPrefix(range("abc"), range("xyz")),
        "Null case",
    );

    try expectEqual(
        @as(usize, 4),
        commonPrefix(range("1234abcdef"), range("1234xyz")),
        "Non-null case",
    );

    try expectEqual(
        @as(usize, 4),
        commonPrefix(range("1234"), range("1234xyz")),
        "Whole case",
    );
}

test commonSuffix {
    try expectEqual(
        @as(usize, 0),
        commonSuffix(range("abc"), range("xyz")),
        "Null case",
    );

    try expectEqual(
        @as(usize, 4),
        commonSuffix(range("abcdef1234"), range("xyz1234")),
        "Non-null case",
    );

    try expectEqual(
        @as(usize, 4),
        commonSuffix(range("1234"), range("xyz1234")),
        "Whole case",
    );
}

test commonOverlap {
    try expectEqual(
        @as(usize, 0),
        commonOverlap(Range.empty, range("abcd")),
        "Null case",
    );
    try expectEqual(
        @as(usize, 3),
        commonOverlap(range("abc"), range("abcd")),
        "Whole case",
    );

    try expectEqual(
        @as(usize, 0),
        commonOverlap(range("123456"), range("abcd")),
        "No overlap",
    );

    try expectEqual(
        @as(usize, 3),
        commonOverlap(range("123456xxx"), range("xxxabcd")),
        "Overlap",
    );

    // Some overly clever languages (C#) may treat ligatures as equal to their
    // component letters. E.g. U+FB01 == 'fi'

    try expectEqual(
        @as(usize, 0),
        commonOverlap(range("fi"), range("\u{fb01}i")),
        "Unicode",
    );
}

fn expectDiffs(
    expected: []const Diff,
    actual: Solution,
    test_name: []const u8,
) !void {
    if (!sameDiffs(expected, actual.diffs.items)) {
        std.log.err(
            "{s}\nexpected:\n{any}\nactual:\n{any}",
            .{ test_name, expected, actual.diffs.items },
        );
        return error.UnexpectedResult;
    }
}

fn _range(doc: []const u8, offset: *usize, text: []const u8) Range {
    const len = std.unicode.utf8CountCodepoints(text) catch unreachable;
    const r = Range.init(doc[offset.*..][0..len]);
    offset.* += len;
    return r;
}

fn diffList(input: []const Diff) !Solution {
    var diffs = DiffList{};
    var text1_ = std.ArrayList(u8).init(talloc);
    var text2_ = std.ArrayList(u8).init(talloc);
    for (input) |diff| switch (diff) {
        .insert => {},
        .delete => try text1_.appendSlice(diff.text().doc),
        .equal => try text1_.appendSlice(diff.text().doc),
    };
    for (input) |diff| switch (diff) {
        .insert => try text2_.appendSlice(diff.text().doc),
        .delete => {},
        .equal => try text2_.appendSlice(diff.text().doc),
    };
    const text1 = Range.init(try text1_.toOwnedSlice());
    const text2 = Range.init(try text2_.toOwnedSlice());
    std.log.debug("text1 '{s}' text2 '{s}'", .{ text1.doc, text2.doc });
    var i: usize = 0;
    var j: usize = 0;
    for (input) |diff| switch (diff) {
        .insert => try diffs.append(talloc, insert(_range(
            text2.doc,
            &j,
            diff.text().doc,
        ).doc)),
        .delete => try diffs.append(talloc, delete(_range(
            text1.doc,
            &i,
            diff.text().doc,
        ).doc)),
        .equal => {
            const r1 = _range(text1.doc, &i, diff.text().doc);
            const r2 = _range(text2.doc, &j, diff.text().doc);
            try diffs.append(talloc, .{ .equal = .{ r1, r2 } });
        },
    };
    return .{ .text1 = text1, .text2 = text2, .diffs = diffs };
}

fn sameDiffs(expecteds: []const Diff, actuals: []const Diff) bool {
    std.log.debug(
        "sameDiffs()\nexpecteds:\n{any}\nactuals:\n{any}",
        .{ expecteds, actuals },
    );
    return expecteds.len == actuals.len and
        for (expecteds) |expected, i|
    {
        const actual = actuals[i];
        const etag = std.meta.activeTag(expected);
        const sametag = etag == std.meta.activeTag(actual);
        const eql = if (etag == .insert and sametag)
            mem.eql(u8, expected.insert.doc, actual.insert.doc)
        else if (etag == .delete and sametag)
            mem.eql(u8, expected.delete.doc, actual.delete.doc)
        else if (etag == .equal and sametag)
            mem.eql(u8, expected.equal[0].doc, actual.equal[0].doc) and
                mem.eql(u8, expected.equal[0].doc, actual.equal[1].doc)
        else
            false;
        if (!eql) break false;
    } else true;
}

const expectCleanupMerge = expectDiffsFn(cleanupMerge);
const expectCleanupSemanticLossless = expectDiffsFn(cleanupSemanticLossless);

const Error = mem.Allocator.Error ||
    error{UnexpectedResult};

fn expectDiffsFn(
    comptime f: fn (mem.Allocator, *Solution) Error!void,
) fn ([]const Diff, []const Diff, comptime []const u8) Error!void {
    return struct {
        fn func(
            input: []const Diff,
            expected: []const Diff,
            comptime test_name: []const u8,
        ) Error!void {
            var solution = try diffList(input);
            defer solution.deinit(talloc);
            try f(talloc, &solution);
            try expectDiffs(expected, solution, test_name);
        }
    }.func;
}

test cleanupMerge {
    try expectCleanupMerge(&.{}, &.{}, "Null case");

    try expectCleanupMerge(
        &.{ equal("a"), delete("b"), insert("c") },
        &.{ equal("a"), delete("b"), insert("c") },
        "No change case",
    );

    try expectCleanupMerge(&.{
        equal("a"),
        equal("b"),
        equal("c"),
    }, &.{equal("abc")}, "Merge equalities");

    try expectCleanupMerge(&.{
        delete("a"),
        delete("b"),
        delete("c"),
    }, &.{delete("abc")}, "Merge deletions");

    try expectCleanupMerge(&.{
        insert("a"),
        insert("b"),
        insert("c"),
    }, &.{insert("abc")}, "Merge insertions");

    try expectCleanupMerge(
        &.{
            delete("a"),
            insert("b"),
            delete("c"),
            insert("d"),
            equal("e"),
            equal("f"),
        },
        &.{ delete("ac"), insert("bd"), equal("ef") },
        "Merge interweave",
    );

    try expectCleanupMerge(
        &.{ delete("a"), insert("abc"), delete("dc") },
        &.{ equal("a"), delete("d"), insert("b"), equal("c") },
        "Prefix and suffix detection",
    );

    try expectCleanupMerge(
        &.{ equal("x"), delete("a"), insert("abc"), delete("dc"), equal("y") },
        &.{ equal("xa"), delete("d"), insert("b"), equal("cy") },
        "Prefix and suffix detection with equalities",
    );

    try expectCleanupMerge(
        &.{ equal("a"), insert("ba"), equal("c") },
        &.{ insert("ab"), equal("ac") },
        "Slide edit left",
    );

    try expectCleanupMerge(
        &.{ equal("c"), insert("ab"), equal("a") },
        &.{ equal("ca"), insert("ba") },
        "Slide edit right",
    );

    try expectCleanupMerge(
        &.{ equal("a"), delete("b"), equal("c"), delete("ac"), equal("x") },
        &.{ delete("abc"), equal("acx") },
        "Slide edit left recursive",
    );

    try expectCleanupMerge(
        &.{ equal("x"), delete("ca"), equal("c"), delete("b"), equal("a") },
        &.{ equal("xca"), delete("cba") },
        "Slide edit right recursive",
    );

    try expectCleanupMerge(
        &.{ delete("b"), insert("ab"), equal("c") },
        &.{ insert("a"), equal("bc") },
        "Empty range",
    );

    try expectCleanupMerge(
        &.{ equal(""), insert("a"), equal("b") },
        &.{ insert("a"), equal("b") },
        "Empty equality",
    );
}

test cleanupSemanticLossless {
    try expectCleanupSemanticLossless(&.{}, &.{}, "Null case");

    testing.log_level = .debug;
    try expectCleanupSemanticLossless(&.{
        equal("AAA\r\n\r\nBBB"),
        insert("\r\nDDD\r\n\r\nBBB"),
        equal("\r\nEEE"),
    }, &.{
        equal("AAA\r\n\r\n"),
        insert("BBB\r\nDDD\r\n\r\n"),
        equal("BBB\r\nEEE"),
    }, "Blank lines");

    try expectCleanupSemanticLossless(&.{
        equal("AAA\r\nBBB"),
        insert(" DDD\r\nBBB"),
        equal(" EEE"),
    }, &.{
        equal("AAA\r\n"),
        insert("BBB DDD\r\n"),
        equal("BBB EEE"),
    }, "Line boundaries");

    try expectCleanupSemanticLossless(&.{
        equal("The c"),
        insert("ow and the c"),
        equal("at."),
    }, &.{
        equal("The "),
        insert("cow and the "),
        equal("cat."),
    }, "Word boundaries");

    try expectCleanupSemanticLossless(&.{
        equal("The-c"),
        insert("ow-and-the-c"),
        equal("at."),
    }, &.{
        equal("The-"),
        insert("cow-and-the-"),
        equal("cat."),
    }, "Alphanumeric boundaries");

    try expectCleanupSemanticLossless(&.{
        equal("a"),
        delete("a"),
        equal("ax"),
    }, &.{
        delete("a"),
        equal("aax"),
    }, "Hitting the start");

    try expectCleanupSemanticLossless(&.{
        equal("xa"),
        delete("a"),
        equal("a"),
    }, &.{
        equal("xaa"),
        delete("a"),
    }, "Hitting the end");

    try expectCleanupSemanticLossless(&.{
        equal("The xxx. The "),
        insert("zzz. The "),
        equal("yyy."),
    }, &.{
        equal("The xxx."),
        insert(" The zzz."),
        equal(" The yyy."),
    }, "Sentence boundaries");
}
