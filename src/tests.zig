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
const range = lib.range;
const talloc = testing.allocator;

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
const expectCleanupSemantic = expectDiffsFn(cleanupSemantic);

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

test cleanupSemantic {
    try expectCleanupSemantic(&.{}, &.{}, "Null case");

    try expectCleanupSemantic(&.{
        delete("ab"),
        insert("cd"),
        equal("12"),
        delete("e"),
    }, &.{
        delete("ab"),
        insert("cd"),
        equal("12"),
        delete("e"),
    }, "No elimination #1");

    try expectCleanupSemantic(&.{
        delete("abc"),
        insert("ABC"),
        equal("1234"),
        delete("wxyz"),
    }, &.{
        delete("abc"),
        insert("ABC"),
        equal("1234"),
        delete("wxyz"),
    }, "No elimination #2");

    try expectCleanupSemantic(&.{
        delete("a"),
        equal("b"),
        delete("c"),
    }, &.{
        delete("abc"),
        insert("b"),
    }, "Simple elimination");

    try expectCleanupSemantic(&.{
        delete("ab"),
        equal("cd"),
        delete("e"),
        equal("f"),
        insert("g"),
    }, &.{
        delete("abcdef"),
        insert("cdfg"),
    }, "Backpass elimination");

    try expectCleanupSemantic(&.{
        insert("1"),
        equal("A"),
        delete("B"),
        insert("2"),
        equal("_"),
        insert("1"),
        equal("A"),
        delete("B"),
        insert("2"),
    }, &.{
        delete("AB_AB"),
        insert("1A2_1A2"),
    }, "Multiple elimination");

    try expectCleanupSemantic(&.{
        equal("The c"),
        delete("ow and the c"),
        equal("at."),
    }, &.{
        equal("The "),
        delete("cow and the "),
        equal("cat."),
    }, "Word boundaries");

    try expectCleanupSemantic(&.{
        delete("abcxx"),
        insert("xxdef"),
    }, &.{
        delete("abcxx"),
        insert("xxdef"),
    }, "No overlap elimination");

    try expectCleanupSemantic(&.{
        delete("abcxxx"),
        insert("xxxdef"),
    }, &.{
        delete("abc"),
        equal("xxx"),
        insert("def"),
    }, "Overlap elimination");

    try expectCleanupSemantic(&.{
        delete("xxxabc"),
        insert("defxxx"),
    }, &.{
        insert("def"),
        equal("xxx"),
        delete("abc"),
    }, "Reverse overlap elimination");

    try expectCleanupSemantic(&.{
        delete("abcd1212"),
        insert("1212efghi"),
        equal("----"),
        delete("A3"),
        insert("3BC"),
    }, &.{
        delete("abcd"),
        equal("1212"),
        insert("efghi"),
        equal("----"),
        delete("A"),
        equal("3"),
        insert("BC"),
    }, "Two overlap eliminations");
}

test bisect {
    const text1 = range(try talloc.dupe(u8, "cat"));
    const text2 = range(try talloc.dupe(u8, "map"));
    var solution = Solution{
        .text1 = text1,
        .text2 = text2,
        .diffs = try bisect(talloc, text1, text2),
    };
    defer solution.deinit(talloc);
    try expectDiffs(&.{
        delete("c"),
        insert("m"),
        equal("a"),
        delete("t"),
        insert("p"),
    }, solution, "Normal");
}

fn expectMain(
    text1: Range,
    text2: Range,
    expected: []const Diff,
    test_name: []const u8,
) !void {
    std.log.debug("-- {s} --", .{test_name});
    var solution =
        try main(talloc, try text1.dupe(talloc), try text2.dupe(talloc));
    defer solution.deinit(talloc);
    try expectDiffs(expected, solution, test_name);
}

test main {
    try expectMain(Range.empty, Range.empty, &.{}, "Null case");

    try expectMain(range("abc"), range("abc"), &.{
        equal("abc"),
    }, "Equality");

    try expectMain(range("abc"), range("ab123c"), &.{
        equal("ab"),
        insert("123"),
        equal("c"),
    }, "Simple insertion");

    try expectMain(range("a123bc"), range("abc"), &.{
        equal("a"),
        delete("123"),
        equal("bc"),
    }, "Simple deletion");

    try expectMain(range("abc"), range("a123b456c"), &.{
        equal("a"),
        insert("123"),
        equal("b"),
        insert("456"),
        equal("c"),
    }, "Two insertions");

    try expectMain(range("a123b456c"), range("abc"), &.{
        equal("a"),
        delete("123"),
        equal("b"),
        delete("456"),
        equal("c"),
    }, "Two deletions");

    try expectMain(range("a"), range("b"), &.{
        delete("a"),
        insert("b"),
    }, "Simple case #1");

    try expectMain(range("Apples are a fruit."), range("Bananas are also fruit."), &.{
        delete("Apple"),
        insert("Banana"),
        equal("s are a"),
        insert("lso"),
        equal(" fruit."),
    }, "Simple case #2");

    try expectMain(range("ax\t"), range("\u{0680}x\x0000"), &.{
        delete("a"),
        insert("\u{0680}"),
        equal("x"),
        delete("\t"),
        insert("\x0000"),
    }, "Simple case #3");

    try expectMain(range("1ayb2"), range("abxab"), &.{
        delete("1"),
        equal("a"),
        delete("y"),
        equal("b"),
        delete("2"),
        insert("xab"),
    }, "Overlap #1");

    try expectMain(range("abcy"), range("xaxcxabc"), &.{
        insert("xaxcx"),
        equal("abc"),
        delete("y"),
    }, "Overlap #2");

    try expectMain(range("ABCDa=bcd=efghijklmnopqrsEFGHIJKLMNOefg"), range("a-bcd-efghijklmnopqrs"), &.{
        delete("ABCD"),
        equal("a"),
        delete("="),
        insert("-"),
        equal("bcd"),
        delete("="),
        insert("-"),
        equal("efghijklmnopqrs"),
        delete("EFGHIJKLMNOefg"),
    }, "Overlap #3");

    try expectMain(range("a [[Pennsylvania]] and [[New"), range(" and [[Pennsylvania]]"), &.{
        insert(" "),
        equal("a"),
        insert("nd"),
        equal(" [[Pennsylvania]]"),
        delete(" and [[New"),
    }, "Large equality");
}
